import AVFoundation
import ScreenCaptureKit

enum RecordingSound: String, CaseIterable {
  case none, system, microphone

  var title: String {
    switch self {
    case .none: return L("无")
    case .system: return L("系统声音")
    case .microphone: return L("麦克风")
    }
  }

  static var available: [Self] {
    if #available(macOS 15, *) { return allCases }
    return [.none, .system]
  }
}

// ScreenCaptureKit timestamps and the pause controls use the same host clock.
struct RecordingTimeline {
  private var origin: CMTime?
  private var segmentStart: CMTime?
  private var pausedAt: CMTime?
  private var skipped = CMTime.zero

  static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
  var isPaused: Bool { pausedAt != nil }
  var hasStarted: Bool { origin != nil }

  mutating func begin(at source: CMTime) {
    guard origin == nil else { return }
    origin = source
    if segmentStart == nil { segmentStart = source }
  }

  mutating func setPaused(_ pause: Bool, at source: CMTime) {
    if pause && pausedAt == nil {
      pausedAt = source
    } else if !pause, let pausedAt {
      if origin != nil { skipped = skipped + max(.zero, source - pausedAt) }
      segmentStart = source
      self.pausedAt = nil
    }
  }

  func accepts(_ source: CMTime) -> Bool {
    !isPaused && source.isNumeric && segmentStart.map { source >= $0 } != false
  }

  func position(of source: CMTime) -> CMTime? {
    guard let origin, accepts(source), source >= origin else { return nil }
    return source - origin - skipped
  }

  func elapsed(at source: CMTime) -> CMTime {
    guard let origin else { return .zero }
    return max(.zero, (pausedAt ?? source) - origin - skipped)
  }
}

struct ScreenRecordingSize {
  let width: Int
  let height: Int

  init(points: CGSize, scale: CGFloat) {
    let multiplier = min(scale, 3840 / max(1, points.width, points.height))
    // The hardware encoders use 4:2:0 and require even dimensions.
    width = max(64, Int(points.width * multiplier) / 2 * 2)
    height = max(64, Int(points.height * multiplier) / 2 * 2)
  }
}

/// A single movie and a single timestamp mapping for picture and sound.
/// Access is serialized by the capture output queue.
final class ScreenRecordingFile {
  private let url: URL
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private let frames: AVAssetWriterInputPixelBufferAdaptor
  private let audio: AVAssetWriterInput?
  private let frameInterval = CMTime(value: 1, timescale: 30)
  private var timeline = RecordingTimeline()
  private var stopTime: CMTime?
  private var latestPausedFrame: CVPixelBuffer?
  private var lastFrame: CVPixelBuffer?
  private var lastVideoTime = CMTime.invalid
  private var audioEnd = CMTime.zero
  private var finished = false

  var didBegin: ((CMTime) -> Void)?

  init(url: URL, size: ScreenRecordingSize, sound: RecordingSound) throws {
    self.url = url
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
    var settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: max(2_000_000, size.width * size.height * 4),
        AVVideoExpectedSourceFrameRateKey: 30, AVVideoAllowFrameReorderingKey: false,
      ],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    if !writer.canApply(outputSettings: settings, forMediaType: .video) {
      settings[AVVideoCodecKey] = AVVideoCodecType.h264
    }
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw EditError.message(L("录屏编码器无法使用这个分辨率。"))
    }
    video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    video.expectsMediaDataInRealTime = true
    frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
    guard writer.canAdd(video) else { throw Self.writeError }
    writer.add(video)
    if sound == .none {
      audio = nil
    } else {
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: sound == .microphone ? 1 : 2, AVEncoderBitRateKey: 128_000,
      ])
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw Self.writeError }
      writer.add(input)
      audio = input
    }
  }

  private static var writeError: EditError { .message(L("无法写入录屏文件。")) }

  func captureVideo(_ image: CVPixelBuffer, at source: CMTime) throws {
    guard !finished, source.isNumeric, stopTime.map({ source <= $0 }) != false else { return }
    if timeline.isPaused {
      latestPausedFrame = image
      return
    }
    guard timeline.accepts(source) else { return }
    let first = !timeline.hasStarted
    if first {
      guard writer.startWriting() else { throw writer.error ?? Self.writeError }
      writer.startSession(atSourceTime: .zero)
      timeline.begin(at: source)
    }
    let needsFirstFrame = !lastVideoTime.isValid
    if let position = timeline.position(of: source) {
      try append(image, at: needsFirstFrame ? .zero : position)
      if needsFirstFrame, lastVideoTime.isValid { didBegin?(source - position) }
    }
  }

  private func append(_ image: CVPixelBuffer, at position: CMTime) throws {
    guard !lastVideoTime.isValid || position > lastVideoTime else { return }
    if writer.status == .failed { throw writer.error ?? Self.writeError }
    guard video.isReadyForMoreMediaData else { return }
    guard frames.append(image, withPresentationTime: position) else { throw writer.error ?? Self.writeError }
    lastVideoTime = position
    lastFrame = image
  }

  func captureAudio(_ sample: CMSampleBuffer) throws {
    let source = sample.presentationTimeStamp
    guard !finished, let audio, let position = timeline.position(of: source),
      stopTime.map({ source <= $0 }) != false, position >= audioEnd else { return }
    if writer.status == .failed { throw writer.error ?? Self.writeError }
    guard audio.isReadyForMoreMediaData else { return }
    let offset = source - position
    let timing = try sample.sampleTimingInfos().map {
      CMSampleTimingInfo(duration: $0.duration, presentationTimeStamp: $0.presentationTimeStamp - offset,
        decodeTimeStamp: $0.decodeTimeStamp.isValid ? $0.decodeTimeStamp - offset : .invalid)
    }
    let adjusted = try CMSampleBuffer(copying: sample, withNewTiming: timing)
    guard audio.append(adjusted) else { throw writer.error ?? Self.writeError }
    audioEnd = sample.duration.isNumeric ? position + sample.duration : position
  }

  func setPaused(_ paused: Bool, at source: CMTime) throws {
    guard !finished, stopTime == nil, timeline.isPaused != paused else { return }
    timeline.setPaused(paused, at: source)
    if !paused {
      // A static screen can stop producing frames while paused. Carry its latest
      // image across the cut so the resumed interval starts with the current desktop.
      if let image = latestPausedFrame, let position = timeline.position(of: source) {
        try append(image, at: position)
      }
      latestPausedFrame = nil
    }
  }

  func stopAccepting(after time: CMTime) { stopTime = time }

  func finish(at source: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
    guard !finished else { return }
    finished = true
    guard let lastFrame, writer.status == .writing else {
      let error = writer.error ?? EditError.message(L("录屏尚未收到画面。"))
      if writer.status == .writing { writer.cancelWriting() }
      removeEmptyFile()
      completion(.failure(error))
      return
    }
    let end = max(lastVideoTime + frameInterval, timeline.elapsed(at: source))
    do {
      if end - lastVideoTime > frameInterval { try append(lastFrame, at: end - frameInterval) }
    } catch {
      removeEmptyFile()
      completion(.failure(error))
      return
    }
    self.lastFrame = nil
    latestPausedFrame = nil
    writer.endSession(atSourceTime: end)
    video.markAsFinished()
    audio?.markAsFinished()
    writer.finishWriting { [self] in
      if writer.status == .completed { completion(.success(url)) }
      else {
        removeEmptyFile()
        completion(.failure(writer.error ?? Self.writeError))
      }
    }
  }

  private func removeEmptyFile() {
    if !lastVideoTime.isValid || (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

final class ScreenRecordingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  private let queue = DispatchQueue(label: "maomijian.screen-recording", qos: .userInitiated)
  private let file: ScreenRecordingFile
  private let interrupted: (Error) -> Void
  private var stream: SCStream!
  private var reportedError = false // capture queue

  init(filter: SCContentFilter, crop: CGRect?, sound: RecordingSound, url: URL,
    began: @escaping (CMTime) -> Void, interrupted: @escaping (Error) -> Void
  ) throws {
    let size = ScreenRecordingSize(points: crop?.size ?? filter.contentRect.size,
      scale: CGFloat(filter.pointPixelScale))
    let settings = SCStreamConfiguration()
    settings.width = size.width
    settings.height = size.height
    if let crop { settings.sourceRect = crop }
    settings.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    settings.colorSpaceName = CGColorSpace.itur_709
    settings.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    settings.queueDepth = 5
    settings.capturesAudio = sound == .system
    if sound == .system {
      settings.sampleRate = 48_000
      settings.channelCount = 2
    }
    if #available(macOS 15, *) { settings.captureMicrophone = sound == .microphone }
    file = try ScreenRecordingFile(url: url, size: size, sound: sound)
    self.interrupted = interrupted
    super.init()
    file.didBegin = began
    stream = SCStream(filter: filter, configuration: settings, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    if sound == .system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
    if #available(macOS 15, *), sound == .microphone {
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    }
  }

  func start() async throws { try await stream.startCapture() }

  func setPaused(_ paused: Bool, at source: CMTime) {
    queue.async { [self] in
      do { try file.setPaused(paused, at: source) }
      catch { report(error) }
    }
  }

  func stop(at source: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
    queue.async { [self] in file.stopAccepting(after: source) }
    Task {
      try? await stream.stopCapture()
      queue.async { [self] in file.finish(at: source, completion: completion) }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    queue.async { [self] in report(error) }
  }

  private func report(_ error: Error) {
    guard !reportedError else { return }
    reportedError = true
    interrupted(error)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard sample.isValid, CMSampleBufferDataIsReady(sample), !reportedError else { return }
    do {
      if type == .screen {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
          as? [[SCStreamFrameInfo: Any]])?.first,
          let status = info[.status] as? Int,
          status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue,
          let image = sample.imageBuffer else { return }
        try file.captureVideo(image, at: sample.presentationTimeStamp)
      } else {
        try file.captureAudio(sample)
      }
    } catch { report(error) }
  }
}
