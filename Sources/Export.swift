import AVFoundation
import Foundation
import VideoToolbox

enum ExportCodec: String, CaseIterable {
  case h264 = "H.264"
  case hevc = "HEVC (H.265)"
  var format: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}
enum ExportQuality: String, CaseIterable {
  case balanced = "均衡"
  case screen = "录屏压缩"
  case high = "高质量"
  case near = "近无损"

  static func available(for codec: ExportCodec) -> [Self] {
    #if arch(arm64)
    if codec == .hevc { return allCases }
    #endif
    return [.balanced, .high, .near]
  }

  var bitsPerPixel: Double {
    switch self {
    case .balanced, .screen: return 0.12
    case .high: return 0.24
    case .near: return 0.76
    }
  }
}
struct ExportSettings: Equatable {
  var short = 1080
  var codec = ExportCodec.hevc
  var quality = ExportQuality.balanced
  var customMbps: Double?
  static let bitrateRange = 0.5...120.0
  static let audioBitrate = 256_000
  var screenCompression: Bool { quality == .screen && codec == .hevc && customMbps == nil }
  var keyframeInterval: Int { (screenCompression ? 6 : 2) * fps }
  var fullSampleLimit: Int { screenCompression ? 3 * keyframeInterval : 8 * fps }

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

enum FrameExportSize: Int, CaseIterable {
  case hd = 1080, qhd = 1440, ultraHD = 2160

  func label(on canvas: Canvas) -> String {
    let dimensions = canvas.size(rawValue)
    let title = self == .ultraHD ? "4K" : "\(rawValue)p"
    return "\(title)  ·  \(Int(dimensions.width)) × \(Int(dimensions.height))"
  }
}

final class ExportJob {
  fileprivate static let audioSampleRate: CMTimeScale = 48_000
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
    if cancelled { throw EditError.message(L("已取消导出。")) }
  }

  func run(_ p: Project, to url: URL, short: Int, progress: @escaping (Double) -> Void) throws {
    try run(p, to: url, settings: ExportSettings(short: short), progress: progress)
  }

  // Stage next to the destination. A failure or cancellation leaves any previous file intact.
  func run(
    _ p: Project, to url: URL, settings: ExportSettings,
    progress: @escaping (Double) -> Void
  ) throws {
    try check()
    guard p.duration > 0 else { throw EditError.message(L("时间线上还没有片段。")) }
    try Self.checkDestination(url, project: p)
    let staged = try MediaScratch.shared.make(.video, beside: url.deletingLastPathComponent())
    defer { withExtendedLifetime(staged) {} }

    let built = try buildComposition(p, short: settings.short, cancelled: { self.cancelled })
    try encode(
      built, to: staged.url, canvas: p.canvas, settings: settings,
      frames: 0..<p.duration, progress: progress)
    try finish { try Self.commit(staged.url, url) }
    progress(1)
  }

  func runAudio(_ p: Project, to url: URL, progress: (Double) -> Void) throws {
    try Self.checkDestination(url, project: p)
    try check()
    let staged = try MediaScratch.shared.make(.audio, beside: url.deletingLastPathComponent())
    defer { withExtendedLifetime(staged) {} }
    try encodeAudio(p, to: staged.url, progress: progress)
    try finish { try Self.commit(staged.url, url) }
    progress(1)
  }

  func runFrame(
    _ p: Project, at position: Int, size: FrameExportSize, to url: URL,
    scratch: MediaScratch = .shared, progress: (Double) -> Void
  ) throws {
    try check()
    guard p.duration > 0 else { throw EditError.message(L("时间线上还没有片段。")) }
    try Self.checkDestination(url, project: p)
    let staged = try scratch.make(.png, beside: url.deletingLastPathComponent())
    defer { withExtendedLifetime(staged) {} }

    let frame = bound(position, 0, p.duration - 1)
    let visible = p.videoVisibility
    let videoIDs = Set(p.clips.filter {
      $0.kind == .video && (visible[$0.id] ?? ($0.start..<$0.end)).contains(frame)
    }.map(\.id))
    let graph = try buildMediaGraph(p, includeAudio: false, videoIDs: videoIDs, cancelled: { self.cancelled })
    let built = try buildComposition(p, short: size.rawValue, reusing: graph, cancelled: { self.cancelled })
    let image: CGImage
    if graph.sources.isEmpty {
      guard let slice = built.instruction(at: frame) as? Slice,
        let context = bitmap(Int(built.video.renderSize.width), Int(built.video.renderSize.height))
      else { throw EditError.message(L("无法导出当前帧。")) }
      var unreadable: URL?
      slice.painter.paint(context, frame: frame, active: slice.compositedClips) { id in
        guard let still = graph.stills[id] else { return nil }
        guard let image = StillImages.image(still, limit: 4096) else {
          unreadable = still
          return nil
        }
        return Picture(image: image, still: true)
      }
      if let unreadable { throw EditError.message(L("无法读取图片「\(unreadable.lastPathComponent)」。")) }
      guard let painted = context.makeImage() else {
        throw EditError.message(L("无法导出当前帧。"))
      }
      image = painted
    } else {
      image = try readFrame(built, at: frame)
    }
    try check()
    progress(0.8)
    try StillImages.writePNG(image, to: staged.url)
    try finish { try Self.commit(staged.url, url) }
    progress(1)
  }

  private func readFrame(_ built: Composition, at frame: Int) throws -> CGImage {
    let reader = try AVAssetReader(asset: built.asset)
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: built.asset.tracks(withMediaType: .video),
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.videoComposition = built.video
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw EditError.message(L("无法读取合成后的画面。")) }
    reader.add(output)
    reader.timeRange = CMTimeRange(start: time(frame), duration: time(1))
    let cancelRead = { if reader.status == .reading { reader.cancelReading() } }
    lock.withLock { stopReading = cancelRead }
    defer {
      lock.withLock { stopReading = nil }
      cancelRead()
    }
    try check()
    guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
      playbackFrame(CMSampleBufferGetPresentationTimeStamp(sample)) == frame,
      let pixels = CMSampleBufferGetImageBuffer(sample)
    else { throw reader.error ?? EditError.message(L("无法导出当前帧。")) }
    var image: CGImage?
    guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr,
      let image else { throw EditError.message(L("无法导出当前帧。")) }
    return image
  }

  func runAudioAndSubtitles(
    _ p: Project, in folder: URL, name: String, progress: (Double) -> Void
  ) throws -> [URL] {
    try check()
    let audio = try MediaScratch.shared.make(.audio, beside: folder)
    let subtitles = try MediaScratch.shared.make(.subtitles, beside: folder)
    let files = FileManager.default
    defer { withExtendedLifetime((audio, subtitles)) {} }
    try Self.writeSubtitles(p, to: subtitles.url)
    try encodeAudio(p, to: audio.url, progress: progress)
    let destinations = try finish {
      var suffix = 1
      while true {
        let base = folder.appendingPathComponent(suffix == 1 ? name : "\(name)-\(suffix)")
        let audioURL = base.appendingPathExtension("m4a")
        let subtitleURL = base.appendingPathExtension("srt")
        if files.fileExists(atPath: audioURL.path) || files.fileExists(atPath: subtitleURL.path) {
          suffix += 1
          continue
        }
        try files.moveItem(at: audio.url, to: audioURL)
        do { try files.moveItem(at: subtitles.url, to: subtitleURL) } catch {
          try? files.removeItem(at: audioURL)
          throw error
        }
        return [audioURL, subtitleURL]
      }
    }
    progress(1)
    return destinations
  }

  static func writeSubtitles(_ p: Project, to url: URL) throws {
    let subtitles = SRT.write(p.clips)
    guard !subtitles.isEmpty else { throw EditError.message(L("时间线上还没有字幕。")) }
    try checkDestination(url, project: p)
    try subtitles.write(to: url, atomically: true, encoding: .utf8)
  }

  static func checkDestination(_ url: URL, project: Project) throws {
    let destination = url.resolvingSymlinksInPath().standardizedFileURL
    guard !project.assets.contains(where: {
      URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL == destination
    }) else { throw EditError.message(L("导出文件不能覆盖原素材。")) }
  }

  // Serialize final replacement with a cancellation requested close to completion.
  private func finish<T>(_ commit: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { throw EditError.message(L("已取消导出。")) }
    return try commit()
  }

  func sampleSize(_ project: Project, settings: ExportSettings) throws -> Int64 {
    try check()
    let frames = project.duration
    guard frames > 0 else { return 0 }
    let built = try buildComposition(project, short: settings.short, cancelled: { self.cancelled })
    let ranges: [Range<Int>]
    if frames <= settings.fullSampleLimit {
      ranges = [0..<frames]
    } else {
      let length = settings.keyframeInterval
      ranges = [1, 3, 5].map { index in
        let start = bound(frames * index / 6 - length / 2, 0, frames - length)
        return start..<start + length
      }
    }
    var bytes: Int64 = 0
    for range in ranges {
      let staged = try MediaScratch.shared.make(.video)
      defer { withExtendedLifetime(staged) {} }
      try encode(built, to: staged.url, canvas: project.canvas, settings: settings, frames: range) { _ in }
      let info = try staged.url.resourceValues(forKeys: [.fileSizeKey])
      guard let size = info.fileSize else { throw EditError.message(L("无法读取抽样文件大小。")) }
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
    built.graph.retainAudio(on: reader)
    writer.shouldOptimizeForNetworkUse = true
    let range = CMTimeRange(start: time(frames.lowerBound), duration: time(frames.count))
    let videoOut = AVAssetReaderVideoCompositionOutput(
      videoTracks: built.asset.tracks(withMediaType: .video),
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    videoOut.videoComposition = built.video
    videoOut.alwaysCopiesSampleData = false
    let videoIn = try videoInput(writer, settings: settings, canvas: canvas)
    guard reader.canAdd(videoOut) else { throw EditError.message(L("无法读取合成后的画面。")) }
    reader.add(videoOut)
    writer.add(videoIn)
    let audio = try audioStream(built.graph, reader: reader, writer: writer)
    try write(reader, writer, range: range, video: ExportStream(input: videoIn, output: videoOut),
              audio: audio, progress: progress)
  }

  private func encodeAudio(_ p: Project, to url: URL, progress: (Double) -> Void) throws {
    try check()
    let graph = try buildMediaGraph(p, includeVideo: false, cancelled: { self.cancelled })
    guard !graph.audio.inputParameters.isEmpty else {
      throw EditError.message(L("时间线上没有可导出的音频。"))
    }
    let reader = try AVAssetReader(asset: graph.asset)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    graph.retainAudio(on: reader)
    guard var audio = try audioStream(graph, reader: reader, writer: writer) else {
      throw EditError.message(L("时间线上没有可导出的音频。"))
    }
    audio.padsAudioToEnd = true
    let range = CMTimeRange(start: .zero, duration: time(p.duration))
    try write(reader, writer, range: range, video: nil, audio: audio, progress: progress)
  }

  private func audioStream(
    _ graph: MediaGraph, reader: AVAssetReader, writer: AVAssetWriter
  ) throws -> ExportStream? {
    let tracks = graph.asset.tracks(withMediaType: .audio)
    guard !tracks.isEmpty else { return nil }
    let audioOut = AVAssetReaderAudioMixOutput(
      audioTracks: tracks,
      audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.audioSampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    audioOut.audioMix = graph.audio
    audioOut.audioTimePitchAlgorithm = .spectral
    audioOut.alwaysCopiesSampleData = false
    let audioIn = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.audioSampleRate, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: ExportSettings.audioBitrate,
      ])
    guard reader.canAdd(audioOut), writer.canAdd(audioIn) else {
      throw EditError.message(L("无法建立导出的音轨。"))
    }
    reader.add(audioOut)
    writer.add(audioIn)
    return ExportStream(input: audioIn, output: audioOut)
  }

  private func write(
    _ reader: AVAssetReader, _ writer: AVAssetWriter, range: CMTimeRange,
    video: ExportStream?, audio: ExportStream?, progress: (Double) -> Void
  ) throws {
    reader.timeRange = range
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
      throw writer.error ?? EditError.message(L("无法启动编码器。"))
    }
    guard reader.startReading() else {
      throw reader.error ?? EditError.message(L("无法读取时间线。"))
    }
    writer.startSession(atSourceTime: range.start)
    var video = video
    var audio = audio
    var lastProgress = 0.0
    while video?.done == false || audio?.done == false {
      try check()
      try verifyIO(reader: reader, writer: writer)
      let advanced = try autoreleasepool {
        let videoTime = try video?.step(until: range.end, writer: writer)
        let audioTime = try audio?.step(until: range.end, writer: writer)
        if let timestamp = video == nil ? audioTime : videoTime {
          let fraction = bound((timestamp - range.start).seconds / range.duration.seconds, 0, 0.995)
          if fraction - lastProgress >= 0.005 {
            lastProgress = fraction
            progress(fraction)
          }
        }
        return videoTime != nil || audioTime != nil
      }
      if !advanced && (video?.done == false || audio?.done == false) {
        Thread.sleep(forTimeInterval: 0.004)
      }
    }
    try check()
    try verifyIO(reader: reader, writer: writer)
    guard ((video ?? audio)?.samples ?? 0) > 0 else {
      throw EditError.message(video == nil ? L("导出没有收到音频采样。") : L("导出没有收到视频帧。"))
    }
    writer.endSession(atSourceTime: range.end)
    let gate = DispatchSemaphore(value: 0)
    writer.finishWriting { gate.signal() }
    while gate.wait(timeout: .now() + 0.15) == .timedOut { try check() }
    try check()
    guard writer.status == .completed else {
      throw writer.error ?? EditError.message(L("系统编码器没有完成导出。"))
    }
  }

  private func videoInput(_ writer: AVAssetWriter, settings: ExportSettings, canvas: Canvas) throws
    -> AVAssetWriterInput
  {
    let size = canvas.size(settings.short)
    var compression: [String: Any] = [
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: settings.keyframeInterval,
    ]
    if settings.screenCompression {
      compression[kVTCompressionPropertyKey_Quality as String] = 0.75
    } else {
      compression[AVVideoAverageBitRateKey] =
        Int((settings.videoMbps(canvas: canvas) * 1_000_000).rounded())
    }
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
      if settings.screenCompression {
        throw EditError.message(L("当前 HEVC 编码器无法使用录屏压缩。请改用均衡档。"))
      }
      throw EditError.message(L("当前编码器不支持这组导出设置。请调低码率或改用另一种编码。"))
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
    guard writer.canAdd(input) else { throw EditError.message(L("无法建立导出的视频轨。")) }
    return input
  }

  private func verifyIO(reader: AVAssetReader, writer: AVAssetWriter) throws {
    if reader.status == .failed {
      throw reader.error ?? EditError.message(L("读取导出帧失败。"))
    }
    if writer.status == .failed {
      throw writer.error ?? EditError.message(L("写入导出帧失败。"))
    }
  }

  static func commit(_ temp: URL, _ url: URL) throws {
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
  var padsAudioToEnd = false
  private var audioTail: (next: CMTime, format: CMFormatDescription)?
  private var drained = false

  init(input: AVAssetWriterInput, output: AVAssetReaderOutput) {
    self.input = input
    self.output = output
  }

  mutating func step(until end: CMTime, writer: AVAssetWriter) throws -> CMTime? {
    guard !done, input.isReadyForMoreMediaData else { return nil }
    if !drained {
      while let sample = output.copyNextSampleBuffer() {
        let pts = sample.presentationTimeStamp
        if pts >= end { break }
        if !CMSampleBufferDataIsReady(sample) || sample.numSamples == 0 { continue }
        try append(sample, writer: writer)
        if padsAudioToEnd, let format = sample.formatDescription {
          audioTail = (
            pts + CMTime(value: Int64(sample.numSamples), timescale: ExportJob.audioSampleRate),
            format)
        }
        return pts
      }
      drained = true
    }
    if let tail = audioTail, let silence = try silence(from: tail.next, until: end, format: tail.format) {
      try append(silence, writer: writer)
      audioTail?.next = tail.next + CMTime(value: Int64(silence.numSamples), timescale: ExportJob.audioSampleRate)
      return tail.next
    }
    if writer.status == .writing { input.markAsFinished() }
    done = true
    return nil
  }

  private mutating func append(_ sample: CMSampleBuffer, writer: AVAssetWriter) throws {
    guard input.append(sample) else {
      throw writer.error ?? EditError.message(L("系统编码器拒绝了时间线采样。"))
    }
    samples += 1
  }

  private func silence(from start: CMTime, until end: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer? {
    // The mix reader emits interleaved, stereo, 16-bit PCM and may stop before the project ends.
    let remaining = (end - start).convertScale(ExportJob.audioSampleRate, method: .roundTowardZero).value
    guard remaining > 0 else { return nil }
    let count = Int(min(8192, remaining))
    let bytes = count * 4
    var block: CMBlockBuffer?
    var sample: CMSampleBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: bytes) == noErr,
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: count, presentationTimeStamp: start, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr, let sample
    else { throw EditError.message(L("无法补齐音频结尾的静音。")) }
    return sample
  }
}
