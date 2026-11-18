import AVFoundation
import Foundation

enum ExportCodec: String, CaseIterable {
  case h264 = "H.264"
  case hevc = "HEVC"
  var format: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}
enum ExportQuality: String, CaseIterable {
  case balanced = "均衡"
  case high = "高质量"
  case near = "近无损"
  var bitsPerPixel: Double {
    switch self {
    case .balanced: return 0.12
    case .high: return 0.24
    case .near: return 0.76
    }
  }
}
struct ExportSettings: Equatable {
  var short = 1080
  var codec = ExportCodec.h264
  var quality = ExportQuality.high
  var customMbps: Double?
  static let bitrateRange = 0.5...120.0
  static let audioBitrate = 256_000

  func videoMbps(canvas: Canvas) -> Double {
    if let customMbps {
      return bound(customMbps, Self.bitrateRange.lowerBound, Self.bitrateRange.upperBound)
    }
    let size = canvas.size(short)
    let efficiency = codec == .hevc ? 0.78 : 1.0
    let target = size.width * size.height * Double(fps) * quality.bitsPerPixel * efficiency
    return max(0.5, (target / 100_000).rounded() / 10)
  }
  func estimatedBytes(for project: Project) -> Int64 {
    guard project.duration > 0 else { return 0 }
    let audio =
      project.clips.contains { clip in
        clip.kind.isMedia && clip.volume > 0 && project.asset(clip.asset)?.audio == true
      } ? Double(Self.audioBitrate) : 0
    let bitsPerSecond = videoMbps(canvas: project.canvas) * 1_000_000 + audio
    let seconds = Double(project.duration) / Double(fps)
    return Int64((seconds * bitsPerSecond / 8 * 1.01 + 32_768).rounded())
  }
}

final class ExportJob {
  private let lock = NSLock()
  private var stopped = false
  private var stopReading: (() -> Void)?
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func cancel() {
    lock.lock()
    stopped = true
    let cancelRead = stopReading
    lock.unlock()
    if let cancelRead { DispatchQueue.global(qos: .utility).async { cancelRead() } }
  }
  private func check() throws {
    if cancelled { throw EditError.message("已取消导出。") }
  }

  func run(_ p: Project, to url: URL, short: Int, progress: @escaping (Double) -> Void) throws {
    try run(p, to: url, settings: ExportSettings(short: short), progress: progress)
  }

  // Stage next to the destination. A failure or cancellation leaves any previous file intact.
  func run(
    _ p: Project, to url: URL, settings: ExportSettings,
    progress: @escaping (Double) -> Void
  ) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(
      ".framecut-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try check()
    guard p.duration > 0 else { throw EditError.message("时间线上还没有片段。") }
    let destination = url.resolvingSymlinksInPath().standardizedFileURL
    guard
      !p.assets.contains(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL == destination
      })
    else { throw EditError.message("导出文件不能覆盖原素材。") }

    let built = try buildComposition(p, short: settings.short, cancelled: { self.cancelled })
    try encode(
      built, to: tmp, canvas: p.canvas, settings: settings,
      frames: 0..<p.duration, progress: progress)
    // Serialize final replacement with a cancellation requested close to completion.
    do {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped else { throw EditError.message("已取消导出。") }
      try commit(tmp, url)
    }
    progress(1)
  }

  func sampleSize(_ project: Project, settings: ExportSettings) throws -> Int64 {
    try check()
    let frames = project.duration
    guard frames > 0 else { return 0 }
    let built = try buildComposition(project, short: settings.short, cancelled: { self.cancelled })
    let ranges: [Range<Int>]
    if frames <= 8 * fps {
      ranges = [0..<frames]
    } else {
      let length = 2 * fps
      ranges = [1, 3, 5].map { index in
        let start = bound(frames * index / 6 - length / 2, 0, frames - length)
        return start..<start + length
      }
    }
    var bytes: Int64 = 0
    for range in ranges {
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
        "framecut-estimate-" + UUID().uuidString + ".mp4")
      defer { try? FileManager.default.removeItem(at: tmp) }
      try encode(built, to: tmp, canvas: project.canvas, settings: settings, frames: range) { _ in }
      let info = try tmp.resourceValues(forKeys: [.fileSizeKey])
      guard let size = info.fileSize else { throw EditError.message("无法读取抽样文件大小。") }
      bytes += Int64(size)
    }
    try check()
    let sampled = ranges.reduce(0) { $0 + $1.count }
    return (bytes * Int64(frames) + Int64(sampled) / 2) / Int64(sampled)
  }

  private func encode(
    _ built: Composition, to tmp: URL, canvas: Canvas, settings: ExportSettings,
    frames: Range<Int>, progress: (Double) -> Void
  ) throws {
    try check()
    let reader = try AVAssetReader(asset: built.asset)
    let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
    built.retainAudio(on: reader)
    writer.shouldOptimizeForNetworkUse = true
    let range = CMTimeRange(start: time(frames.lowerBound), duration: time(frames.count))
    reader.timeRange = range

    let videoOut = AVAssetReaderVideoCompositionOutput(
      videoTracks: built.asset.tracks(withMediaType: .video),
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    videoOut.videoComposition = built.video
    videoOut.alwaysCopiesSampleData = false
    let videoIn = try videoInput(writer, settings: settings, canvas: canvas)
    guard reader.canAdd(videoOut) else { throw EditError.message("无法读取合成后的画面。") }
    reader.add(videoOut)
    writer.add(videoIn)
    var audio: ExportStream?
    let tracks = built.asset.tracks(withMediaType: .audio)
    if !tracks.isEmpty {
      let audioOut = AVAssetReaderAudioMixOutput(
        audioTracks: tracks,
        audioSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      audioOut.audioMix = built.audio
      audioOut.audioTimePitchAlgorithm = .spectral
      audioOut.alwaysCopiesSampleData = false
      let audioIn = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: ExportSettings.audioBitrate,
        ])
      guard reader.canAdd(audioOut), writer.canAdd(audioIn) else {
        throw EditError.message("无法建立导出的音轨。")
      }
      reader.add(audioOut)
      writer.add(audioIn)
      audio = ExportStream(input: audioIn, output: audioOut)
    }

    let cancelRead = { if reader.status == .reading { reader.cancelReading() } }
    lock.lock()
    stopReading = cancelRead
    lock.unlock()
    defer {
      lock.lock()
      stopReading = nil
      lock.unlock()
      cancelRead()
      if writer.status == .writing { writer.cancelWriting() }
    }
    try check()
    guard writer.startWriting() else {
      throw writer.error ?? EditError.message("无法启动视频编码器。")
    }
    guard reader.startReading() else {
      throw reader.error ?? EditError.message("无法读取时间线。")
    }
    writer.startSession(atSourceTime: range.start)
    var video = ExportStream(input: videoIn, output: videoOut)
    var lastProgress = 0.0
    while !video.done || audio?.done == false {
      try check()
      try verifyIO(reader: reader, writer: writer)
      var advanced = false
      try autoreleasepool {
        if let timestamp = try video.step(until: range.end, writer: writer) {
          let fraction = bound((timestamp - range.start).seconds / range.duration.seconds, 0, 0.995)
          if fraction - lastProgress >= 0.005 {
            lastProgress = fraction
            progress(fraction)
          }
          advanced = true
        }
        if try audio?.step(until: range.end, writer: writer) != nil { advanced = true }
      }
      if !advanced && (!video.done || audio?.done == false) {
        Thread.sleep(forTimeInterval: 0.004)
      }
    }
    try check()
    try verifyIO(reader: reader, writer: writer)
    guard video.samples > 0 else { throw EditError.message("导出没有收到视频帧。") }
    writer.endSession(atSourceTime: range.end)
    let gate = DispatchSemaphore(value: 0)
    writer.finishWriting { gate.signal() }
    while gate.wait(timeout: .now() + 0.15) == .timedOut { try check() }
    try check()
    guard writer.status == .completed else {
      throw writer.error ?? EditError.message("系统编码器没有完成导出。")
    }
  }

  private func videoInput(_ writer: AVAssetWriter, settings: ExportSettings, canvas: Canvas) throws
    -> AVAssetWriterInput
  {
    let size = canvas.size(settings.short)
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: Int((settings.videoMbps(canvas: canvas) * 1_000_000).rounded()),
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: fps * 2,
    ]
    if settings.codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    let output: [String: Any] = [
      AVVideoCodecKey: settings.codec.format,
      AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    guard writer.canApply(outputSettings: output, forMediaType: .video) else {
      throw EditError.message("当前编码器不支持这组导出设置。请调低码率或改用另一种编码。")
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
    guard writer.canAdd(input) else { throw EditError.message("无法建立导出的视频轨。") }
    return input
  }

  private func verifyIO(reader: AVAssetReader, writer: AVAssetWriter) throws {
    if reader.status == .failed {
      throw reader.error ?? EditError.message("读取导出帧失败。")
    }
    if writer.status == .failed {
      throw writer.error ?? EditError.message("写入导出帧失败。")
    }
  }

  private func commit(_ temp: URL, _ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } else {
      try FileManager.default.moveItem(at: temp, to: url)
    }
  }
}

private struct ExportStream {
  let input: AVAssetWriterInput
  let output: AVAssetReaderOutput
  var done = false
  var samples = 0

  mutating func step(until end: CMTime, writer: AVAssetWriter) throws -> CMTime? {
    guard !done, input.isReadyForMoreMediaData else { return nil }
    while let sample = output.copyNextSampleBuffer() {
      let pts = sample.presentationTimeStamp
      if pts >= end { break }
      if !CMSampleBufferDataIsReady(sample) || sample.numSamples == 0 { continue }
      guard input.append(sample) else {
        throw writer.error ?? EditError.message("系统编码器拒绝了时间线采样。")
      }
      samples += 1
      return pts
    }
    if writer.status == .writing { input.markAsFinished() }
    done = true
    return nil
  }
}
