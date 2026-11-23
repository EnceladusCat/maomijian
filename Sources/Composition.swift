import AVFoundation
import AppKit
import VideoToolbox

func playbackFrame(_ timestamp: CMTime) -> Int? {
  guard timestamp.isNumeric, timestamp >= .zero, timestamp <= time(maxFrames) else { return nil }
  return Int(CMTimeConvertScale(timestamp, timescale: Int32(fps), method: .roundTowardZero).value)
}

func time(_ f: Int) -> CMTime { CMTime(value: Int64(f), timescale: 30) }

enum PreviewRenderFailure: Int, LocalizedError, CustomNSError {
  case instruction = 1, pixelBuffer, canvas

  static let errorDomain = "local.framecut.preview.render"
  var errorCode: Int { rawValue }
  var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
  var errorDescription: String? {
    switch self {
    case .instruction: return L("无法读取当前画面的预览指令。")
    case .pixelBuffer: return L("无法分配预览画面。")
    case .canvas: return L("无法创建画布。")
    }
  }

  static func matches(_ error: Error?) -> Bool {
    var underlying = error as NSError?
    for _ in 0..<6 {
      guard let current = underlying else { return false }
      if current.domain == errorDomain { return true }
      underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}

struct SourceMap {
  let track: CMPersistentTrackID
  let transform: CGAffineTransform
  let opaque: Bool
}
final class PreviewPlayback {
  private let lock = NSLock()
  private var playing = false
  private var scrubbing = false

  var isPlaying: Bool { lock.withLock { playing } }
  var capturesPausedFrames: Bool { lock.withLock { !playing && !scrubbing } }
  func setPlaying(_ value: Bool) { lock.withLock { playing = value } }
  func setScrubbing(_ value: Bool) { lock.withLock { scrubbing = value } }
}

final class Slice: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false, containsTweening = true
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let requiredSourceTrackIDs: [NSValue]?
  let preview: Bool
  let playback: PreviewPlayback?
  let canvasFrames: CanvasFrames?
  let stills: [UUID: URL]
  let painter: FramePainter, clips: [Clip], sources: [UUID: SourceMap]
  let plainVideo: Clip?
  let captions: [Clip]
  let compositedClips: [Clip]
  let presentsCaptionsSeparately: Bool
  let inlineCaptions: [Clip]
  let animatedCaptions: Bool
  init(
    _ range: CMTimeRange, _ clips: [Clip], _ sources: [UUID: SourceMap],
    _ clock: CMPersistentTrackID, _ painter: FramePainter, preview: Bool,
    playback: PreviewPlayback?, canvasFrames: CanvasFrames?, stills: [UUID: URL]
  ) {
    self.preview = preview
    self.playback = playback
    self.canvasFrames = canvasFrames
    self.stills = stills
    timeRange = range
    self.clips = clips
    let editing = preview && playback != nil
    captions = clips.filter { $0.kind == .caption }
    compositedClips = editing ? clips.filter { $0.kind != .caption } : clips
    // Audio-only and empty intervals can show subtitles without a decoded frame.
    // A visual interval publishes its picture and subtitles in one buffer.
    presentsCaptionsSeparately = editing && compositedClips.isEmpty
    inlineCaptions = editing ? captions : []
    animatedCaptions = captions.contains { $0.motion != .none || $0.entranceFrames > 0 }
    self.sources = sources
    self.painter = painter
    if let clip = clips.first(where: { $0.kind == .video }),
      clips.allSatisfy({ $0.kind == .caption || $0.id == clip.id }),
      let source = sources[clip.id], source.opaque, source.transform.isIdentity,
      clip.x == 0.5, clip.y == 0.5, clip.angle == 0, clip.opacity == 1, clip.displayScale == 1,
      clip.sourceCrop == nil, clip.visualBorder == nil, clip.pictureInset == nil, clip.filters.isEmpty,
      clip.motion == .none, clip.entranceFrames == 0,
      clip.from == nil, clip.startEffect == nil, clip.endEffect == nil
    {
      plainVideo = clip
    } else {
      plainVideo = nil
    }
    requiredSourceTrackIDs = ([clock] + sources.values.map(\.track)).map { NSNumber(value: $0) }
  }
}
// Resize high-resolution sources before Quartz composites the editing preview.
private final class PreviewScaler {
  private let lock = NSLock()
  private var transfer: VTPixelTransferSession?
  private var pools: [Int64: CVPixelBufferPool] = [:]
  func scaled(_ source: CVPixelBuffer, fitting canvas: CGSize, transform: CGAffineTransform)
    -> CVPixelBuffer
  {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
    let ratio = min(canvas.width / bounds.width, canvas.height / bounds.height)
    guard ratio > 0, ratio < 0.9 else { return source }
    let w = max(2, Int((CGFloat(width) * ratio).rounded()))
    let h = max(2, Int((CGFloat(height) * ratio).rounded()))
    lock.lock()
    defer { lock.unlock() }
    if transfer == nil {
      guard
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr,
        let transfer
      else { return source }
      VTSessionSetProperty(
        transfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
    }
    let key = Int64(w) << 32 | Int64(h)
    if pools[key] == nil {
      let props: [String: Any] = [
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ]
      var pool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(nil, nil, props as CFDictionary, &pool) == kCVReturnSuccess
      else { return source }
      if pools.count >= 4 { pools.removeAll() }
      pools[key] = pool
    }
    var dest: CVPixelBuffer?
    guard let transfer, let pool = pools[key],
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest) == kCVReturnSuccess, let dest,
      VTPixelTransferSessionTransferImage(transfer, from: source, to: dest) == noErr
    else { return source }
    return dest
  }
}
final class Compositor: NSObject, AVVideoCompositing {
  private final class Requests {
    let cancellation = Progress(totalUnitCount: 0)
    let pending = DispatchGroup()
  }

  private let scaler = PreviewScaler()
  private let lock = NSLock()
  private var requests = Requests()
  private let workers: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "framecut.compositor"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 3
    return queue
  }()
  let sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ]
  let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ]
  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    lock.lock()
    let batch = requests
    batch.pending.enter()
    lock.unlock()
    let render = { [self] in
      defer { batch.pending.leave() }
      if batch.cancellation.isCancelled {
        request.finishCancelledRequest()
      } else {
        self.render(request, cancellation: batch.cancellation)
      }
    }
    if let slice = request.videoCompositionInstruction as? Slice,
      slice.preview && slice.playback?.isPlaying != true
    {
      // Exact paused seeks use the current request immediately. Playback and
      // export can keep multiple independent frames in flight.
      render()
    } else {
      workers.addOperation(render)
    }
  }

  func cancelAllPendingVideoCompositionRequests() {
    lock.lock()
    let previous = requests
    requests = Requests()
    lock.unlock()
    previous.cancellation.cancel()
    previous.pending.wait()
  }

  static func copyMatchingFrame(_ source: CVPixelBuffer, to destination: CVPixelBuffer, size: CGSize)
    -> Bool
  {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard CGFloat(width) == size.width, CGFloat(height) == size.height,
      width == CVPixelBufferGetWidth(destination), height == CVPixelBufferGetHeight(destination),
      CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
      CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess
    else { return false }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    guard let input = CVPixelBufferGetBaseAddress(source),
      let output = CVPixelBufferGetBaseAddress(destination)
    else { return false }
    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let destinationStride = CVPixelBufferGetBytesPerRow(destination)
    let bytes = width * 4
    if sourceStride == bytes && destinationStride == bytes {
      memcpy(output, input, bytes * height)
    } else {
      for row in 0..<height {
        memcpy(output + row * destinationStride, input + row * sourceStride, bytes)
      }
    }
    return true
  }

  private func render(
    _ request: AVAsynchronousVideoCompositionRequest, cancellation: Progress
  ) {
    #if FRAME_BENCH
      let start = CFAbsoluteTimeGetCurrent()
      var direct = false
      var verificationTime = 0.0
      defer {
        RenderStatistics.record(
          playbackFrame(request.compositionTime) ?? 0,
          1000 * (CFAbsoluteTimeGetCurrent() - start - verificationTime), direct: direct)
      }
    #endif
    autoreleasepool {
      guard let s = request.videoCompositionInstruction as? Slice else {
        request.finish(with: PreviewRenderFailure.instruction)
        return
      }
      guard let out = request.renderContext.newPixelBuffer() else {
        request.finish(with: PreviewRenderFailure.pixelBuffer)
        return
      }
      let frame = playbackFrame(request.compositionTime) ?? 0
      let captures = s.playback?.capturesPausedFrames == true ? s.canvasFrames : nil
      var pictures = [UUID: Picture]()
      func picture(_ id: UUID, canvas: CGSize) -> Picture? {
        if let url = s.stills[id],
          let im = StillImages.image(url, limit: s.preview ? StillImages.previewLimit : 4096)
        {
          return Picture(image: im, still: true)
        }
        guard let m = s.sources[id], let original = request.sourceFrame(byTrackID: m.track) else {
          return nil
        }
        let buf =
          s.preview
          ? scaler.scaled(original, fitting: canvas, transform: m.transform) : original
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        guard let ptr = CVPixelBufferGetBaseAddress(buf) else {
          CVPixelBufferUnlockBaseAddress(buf, .readOnly)
          return nil
        }
        let ref = Unmanaged.passRetained(buf).toOpaque()
        guard
          let provider = CGDataProvider(
            dataInfo: ref, data: ptr,
            size: CVPixelBufferGetBytesPerRow(buf) * CVPixelBufferGetHeight(buf),
            releaseData: { info, _, _ in
              let value = Unmanaged<CVPixelBuffer>.fromOpaque(info!).takeRetainedValue()
              CVPixelBufferUnlockBaseAddress(value, .readOnly)
            })
        else {
          Unmanaged<CVPixelBuffer>.fromOpaque(ref).release()
          CVPixelBufferUnlockBaseAddress(buf, .readOnly)
          return nil
        }
        guard
          let im = CGImage(
            width: CVPixelBufferGetWidth(buf), height: CVPixelBufferGetHeight(buf),
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: rgb, bitmapInfo: CGBitmapInfo(rawValue: bgra), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Picture(image: im, transform: m.transform)
      }
      var copied = false
      if let clip = s.plainVideo, let source = s.sources[clip.id],
        let input = request.sourceFrame(byTrackID: source.track),
        Self.copyMatchingFrame(input, to: out, size: s.painter.size)
      {
        copied = true
        if captures != nil { pictures[clip.id] = picture(clip.id, canvas: s.painter.size) }
      }
      // In export, captions are normally rendered with the scene. The direct
      // copy skips that draw, so paint those captions on top of the copied frame.
      let captions = copied ? s.captions : s.inlineCaptions
      if !copied || !captions.isEmpty {
        guard CVPixelBufferLockBaseAddress(out, []) == kCVReturnSuccess else {
          request.finish(with: PreviewRenderFailure.canvas)
          return
        }
        guard let data = CVPixelBufferGetBaseAddress(out), let g = bitmap(
          CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out),
          data: data, row: CVPixelBufferGetBytesPerRow(out))
        else {
          CVPixelBufferUnlockBaseAddress(out, [])
          request.finish(with: PreviewRenderFailure.canvas)
          return
        }
        // AVFoundation may change the backing size for a render context.
        g.scaleBy(
          x: CGFloat(CVPixelBufferGetWidth(out)) / s.painter.size.width,
          y: CGFloat(CVPixelBufferGetHeight(out)) / s.painter.size.height)
        if !copied {
          s.painter.paint(g, frame: frame, active: s.compositedClips) { id, canvas in
            let result = picture(id, canvas: canvas)
            if let result, captures != nil { pictures[id] = result }
            return result
          }
        }
        if !captions.isEmpty { s.painter.paintCaptions(g, frame: frame, active: captions) }
        g.flush()
        CVPixelBufferUnlockBaseAddress(out, [])
      }
      #if FRAME_BENCH
        direct = copied
        if copied, frame % 211 == 0, let reference = bitmap(CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out)) {
          let began = CFAbsoluteTimeGetCurrent()
          s.painter.paint(reference, frame: frame, active: s.compositedClips, sourceForCanvas: picture)
          if !s.inlineCaptions.isEmpty { s.painter.paintCaptions(reference, frame: frame, active: s.inlineCaptions) }
          reference.flush()
          CVPixelBufferLockBaseAddress(out, .readOnly)
          let actual = CVPixelBufferGetBaseAddress(out)!
          let expected = reference.data!
          let rowsMatch = (0..<reference.height).allSatisfy { row in
            memcmp(actual + row * CVPixelBufferGetBytesPerRow(out),
                   expected + row * reference.bytesPerRow, reference.width * 4) == 0
          }
          CVPixelBufferUnlockBaseAddress(out, .readOnly)
          RenderStatistics.recordParity(frame, matches: rowsMatch)
          verificationTime = CFAbsoluteTimeGetCurrent() - began
        }
      #endif
      if cancellation.isCancelled { request.finishCancelledRequest() }
      else {
        captures?.store(CanvasFrame(number: frame, painter: s.painter, clips: s.compositedClips,
                                   pictures: pictures, captions: s.inlineCaptions))
        request.finish(withComposedVideoFrame: out)
      }
    }
  }
}
struct MediaGraph {
  let asset: AVMutableComposition, audio: AVMutableAudioMix
  let sources: [UUID: SourceMap], clock: CMPersistentTrackID
  let pitchFiles: [PitchedAudio]
  let stills: [UUID: URL]

  func retainAudio(on object: AnyObject) {
    if !pitchFiles.isEmpty {
      objc_setAssociatedObject(object, &audioLeaseKey, pitchFiles, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}
private var audioLeaseKey: UInt8 = 0
struct Composition {
  let graph: MediaGraph, video: AVMutableVideoComposition
  var canvasFrames: CanvasFrames? = nil
  var scrubPainter: FramePainter? = nil
  var captionOnlyPreview = false
  var asset: AVMutableComposition { graph.asset }
  var audio: AVMutableAudioMix { graph.audio }
  func item() -> AVPlayerItem {
    let i = AVPlayerItem(asset: asset)
    i.videoComposition = video
    i.audioMix = audio
    i.audioTimePitchAlgorithm = .spectral
    graph.retainAudio(on: i)
    return i
  }

  /// Keep transient seek tolerance within the current composite slice so the
  /// preview cannot jump across a cut, caption or effect boundary.
  func scrubTolerance(at frame: Int) -> (before: CMTime, after: CMTime) {
    let requested = time(frame)
    guard let slice = instruction(at: frame) else { return (.zero, .zero) }
    let range = slice.timeRange
    let tolerance = time(12)
    return (
      CMTimeMinimum(tolerance, CMTimeMaximum(.zero, requested - range.start)),
      CMTimeMinimum(tolerance, CMTimeMaximum(.zero, range.end - time(1) - requested))
    )
  }

  func instruction(at frame: Int) -> AVVideoCompositionInstructionProtocol? {
    let requested = time(frame)
    let slices = video.instructions
    var low = 0, high = slices.count
    while low < high {
      let middle = (low + high) / 2
      if slices[middle].timeRange.end <= requested { low = middle + 1 } else { high = middle }
    }
    guard slices.indices.contains(low), slices[low].timeRange.start <= requested else { return nil }
    return slices[low]
  }

  func captionPreview(at frame: Int) -> (slice: Slice, frame: Int)? {
    // Only intervals without visual media need an independent caption surface.
    let end = video.instructions.last?.timeRange.end.seconds ?? 0
    let last = max(0, Int((end * Double(fps)).rounded()) - 1)
    let target = min(frame, last)
    guard let slice = instruction(at: target) as? Slice, slice.presentsCaptionsSeparately,
      !slice.captions.isEmpty || slice.compositedClips.isEmpty
    else { return nil }
    let start = Int((slice.timeRange.start.seconds * Double(fps)).rounded())
    return (slice, slice.animatedCaptions ? target : start)
  }

  func canvasFrame(at frame: Int) -> CanvasFrame? {
    guard let canvasFrames else { return nil }
    if let recent = canvasFrames.frame(frame) { return recent }
    // The current frame may have been composed while playing. Decode it only
    // when a paused frame is missing, then reuse the snapshot for the gesture.
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: asset.tracks(withMediaType: .video),
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.videoComposition = video
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    reader.timeRange = CMTimeRange(start: time(frame), duration: time(1))
    guard reader.startReading() else { return nil }
    defer { reader.cancelReading() }
    guard output.copyNextSampleBuffer() != nil else { return nil }
    return canvasFrames.frame(frame)
  }
}
private func sourceTime(_ frame: Double) -> CMTime {
  CMTime(value: Int64((frame * 20000).rounded()), timescale: 600000)
}
func clockURL() throws -> URL {
  guard let u = Bundle.main.url(forResource: "Clock", withExtension: "mp4") else {
    throw EditError.message(L("应用缺少 Clock.mp4 资源。"))
  }
  return u
}
func inspect(_ u: URL) throws -> Media {
  if StillImages.dimensions(u) != nil, StillImages.image(u, limit: 160) != nil {
    return Media(
      path: u.standardizedFileURL.path, frames: 150, video: true, audio: false, still: true)
  }
  let a = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
  let v = !a.tracks(withMediaType: .video).isEmpty
  let s = !a.tracks(withMediaType: .audio).isEmpty
  let sec = a.duration.seconds
  guard a.isPlayable, sec.isFinite, sec >= 1.0 / 30, sec <= 86400, v || s else {
    throw EditError.message(L("无法读取「\(u.lastPathComponent)」。请使用系统可解码的图片、视频或音频文件。"))
  }
  return Media(
    path: u.standardizedFileURL.path, frames: max(1, Int(floor(sec * 30 + 0.00001))), video: v,
    audio: s)
}
// Fill missing media handles by stretching only the edge sample. The next
// ordinary frame and the original audio retain their authored timestamps.
private func insertVideo(
  _ clip: Clip, visible: Range<Int>, source: AVAssetTrack, into lane: AVMutableCompositionTrack
) throws {
  let start = time(visible.lowerBound)
  let length = time(visible.count)
  let wanted = CMTimeRange(
    start: sourceTime(clip.sourceFrame(at: visible.lowerBound)),
    end: sourceTime(clip.sourceFrame(at: visible.upperBound)))
  let available = source.timeRange
  let core = CMTimeRangeGetIntersection(wanted, otherRange: available)
  guard core.isValid, core.duration > .zero else { return }
  func hold(from edge: CMTime, at target: CMTime, duration: CMTime) throws {
    guard duration > .zero else { return }
    let tick = CMTimeMinimum(
      available.duration, CMTime(value: 1, timescale: max(600, source.naturalTimeScale)))
    let sample = CMTimeRange(start: CMTimeMinimum(edge, available.end - tick), duration: tick)
    try lane.insertTimeRange(sample, of: source, at: target)
    lane.scaleTimeRange(CMTimeRange(start: target, duration: tick), toDuration: duration)
  }
  let lead = CMTimeMultiplyByFloat64(core.start - wanted.start, multiplier: 1 / clip.effectiveRate)
  let coreDuration = CMTimeMultiplyByFloat64(core.duration, multiplier: 1 / clip.effectiveRate)
  // Container duration can exceed the picture track by a frame or two because of
  // audio packet padding. Extend the nearby picture through that short gap.
  if visible.lowerBound < clip.start || lead <= time(2) {
    try hold(from: available.start, at: start, duration: lead)
  }
  try lane.insertTimeRange(core, of: source, at: start + lead)
  if core.duration != coreDuration {
    lane.scaleTimeRange(
      CMTimeRange(start: start + lead, duration: core.duration), toDuration: coreDuration)
  }
  let tail = length - lead - coreDuration
  if visible.upperBound > clip.end || tail <= time(2) {
    try hold(
      from: available.end, at: start + lead + coreDuration, duration: tail)
  }
}
func buildMediaGraph(
  _ p: Project, includeVideo: Bool = true, includeAudio: Bool = true,
  videoIDs: Set<UUID>? = nil, cancelled: () -> Bool
) throws -> MediaGraph {
  guard p.duration > 0 else { throw EditError.message(L("时间线上还没有片段。")) }
  let a = AVMutableComposition()
  var pitchFiles = [PitchedAudio]()
  let mix = AVMutableAudioMix()
  var clock = kCMPersistentTrackID_Invalid
  if includeVideo {
    let base = AVURLAsset(url: try clockURL())
    guard let track = base.tracks(withMediaType: .video).first,
      let clk = a.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw EditError.message(L("无法建立预览轨道。")) }
    try clk.insertTimeRange(track.timeRange, of: track, at: .zero)
    clk.scaleTimeRange(track.timeRange, toDuration: time(p.duration))
    clock = clk.trackID
  }
  let visibleVideo = includeVideo ? p.videoVisibility : [:]
  var sources = [UUID: SourceMap]()
  var stills = [UUID: URL]()
  var checkedStills = Set<UUID>()
  var assets = [UUID: (asset: AVURLAsset, video: AVAssetTrack?, audio: AVAssetTrack?)]()
  var pools = [AVMediaType: [(AVMutableCompositionTrack, Int)]]()
  var volumes = [CMPersistentTrackID: AVMutableAudioMixInputParameters]()
  let mediaByID = p.mediaByID
  var availablePaths = Set<String>()
  for c in p.clips.sorted(by: { $0.start < $1.start }) where c.kind.isMedia {
    if cancelled() { throw EditError.message(L("预览更新已替换。")) }
    let needsVideo = includeVideo && c.kind == .video && (videoIDs?.contains(c.id) ?? true)
    let needsAudio = includeAudio && c.volume > 0
    guard needsVideo || needsAudio else { continue }
    guard let media = c.asset.flatMap({ mediaByID[$0] }) else {
      throw EditError.message(L("找不到「\(p.name(c))」。请在素材列表中重新定位文件。"))
    }
    if !needsVideo, media.isStill { continue }
    if !availablePaths.contains(media.path) {
      guard FileManager.default.fileExists(atPath: media.path) else {
        if !includeVideo, c.kind == .video, !media.audio { continue }
        throw EditError.message(L("找不到「\(p.name(c))」。请在素材列表中重新定位文件。"))
      }
      availablePaths.insert(media.path)
    }
    if media.isStill {
      let url = URL(fileURLWithPath: media.path)
      if checkedStills.insert(media.id).inserted, StillImages.dimensions(url) == nil {
        throw EditError.message(L("无法读取图片「\(media.name)」。"))
      }
      stills[c.id] = url
      continue
    }
    if assets[media.id] == nil {
      let asset = AVURLAsset(
        url: URL(fileURLWithPath: media.path),
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      assets[media.id] = (
        asset, includeVideo ? asset.tracks(withMediaType: .video).first : nil,
        includeAudio ? asset.tracks(withMediaType: .audio).first : nil)
    }
    guard let source = assets[media.id] else { continue }
    var tracks: [(AVMediaType, AVAssetTrack)] = []
    if needsVideo {
      guard let video = source.video else {
        throw EditError.message(L("无法读取「\(media.name)」的轨道。"))
      }
      tracks.append((.video, video))
    }
    if needsAudio {
      if let audio = source.audio { tracks.append((.audio, audio)) }
      else if c.kind == .audio { throw EditError.message(L("无法读取「\(media.name)」的音轨。")) }
    }
    for (type, original) in tracks {
      let span = type == .video ? visibleVideo[c.id] ?? (c.start..<c.end) : (c.start..<c.end)
      let desired = CMTimeRange(
        start: sourceTime(c.sourceFrame(at: span.lowerBound)),
        end: sourceTime(c.sourceFrame(at: span.upperBound)))
      let range = CMTimeRangeGetIntersection(desired, otherRange: original.timeRange)
      guard range.isValid, range.duration.seconds > 0 else { continue }
      var lanes = pools[type] ?? []
      let lane: AVMutableCompositionTrack
      if let i = lanes.firstIndex(where: { $0.1 <= span.lowerBound }) {
        lane = lanes[i].0
        lanes[i].1 = span.upperBound
      } else {
        guard
          let t = a.addMutableTrack(
            withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw EditError.message(L("轨道数量超出系统限制。")) }
        lane = t
        lanes.append((t, span.upperBound))
      }
      pools[type] = lanes
      if type == .video {
        try insertVideo(c, visible: span, source: original, into: lane)
        let formats = original.formatDescriptions as? [CMFormatDescription] ?? []
        let opaque = !formats.isEmpty && !original.hasMediaCharacteristic(.containsAlphaChannel)
          && formats.allSatisfy {
            [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType($0))
          }
        sources[c.id] = SourceMap(
          track: lane.trackID, transform: original.preferredTransform, opaque: opaque)
      } else {
        let start =
          time(c.start)
          + CMTimeMultiplyByFloat64(range.start - desired.start, multiplier: 1 / c.effectiveRate)
        let duration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / c.effectiveRate)
        let input: AVAssetTrack
        let inputRange: CMTimeRange
        if c.pitch != 0 {
          let file = try PitchedAudio.make(
            source.asset, track: original, range: range, semitones: c.pitch, cancelled: cancelled)
          pitchFiles.append(file)
          let pitchedAsset = file.readable
          guard let t = pitchedAsset.tracks(withMediaType: .audio).first else {
            throw EditError.message(L("无法读取变调后的音轨。"))
          }
          input = t
          inputRange = t.timeRange
        } else {
          input = original
          inputRange = range
        }
        do { try lane.insertTimeRange(inputRange, of: input, at: start) } catch {
          throw EditError.message(L("无法合成「\(media.name)」的音轨。") + " " + error.localizedDescription)
        }
        if inputRange.duration != duration {
          lane.scaleTimeRange(
            CMTimeRange(start: start, duration: inputRange.duration), toDuration: duration)
        }
        let par = volumes[lane.trackID] ?? AVMutableAudioMixInputParameters(track: lane)
        par.audioTimePitchAlgorithm = .spectral
        par.setVolume(Float(c.volume), at: time(c.start))
        volumes[lane.trackID] = par
      }
    }
  }
  mix.inputParameters = Array(volumes.values)
  return MediaGraph(
    asset: a, audio: mix, sources: sources, clock: clock, pitchFiles: pitchFiles,
    stills: stills)
}
func buildComposition(
  _ p: Project, short: Int, preview: Bool = false, reusing existing: MediaGraph? = nil,
  playback: PreviewPlayback? = nil, cancelled: () -> Bool = { false }
) throws -> Composition {
  let graph = try existing ?? buildMediaGraph(p, cancelled: cancelled)
  let visibleVideo = p.videoVisibility
  let visibleArtwork = p.artworkTransitionVisibility
  let vc = AVMutableVideoComposition()
  let size = p.canvas.size(short)
  let signals = audioSignals(in: p, cancelled: cancelled)
  if cancelled() { throw EditError.message(L("预览更新已替换。")) }
  var pictureProject = p
  if preview && playback != nil {
    // The picture painter can borrow artwork from transition groups.
    // Keep the separately drawn captions out of that lookup as well.
    pictureProject.clips.removeAll { $0.kind == .caption }
  }
  let painter = FramePainter(pictureProject, size, preview: preview, audioSignals: signals)
  let canvasFrames = playback == nil ? nil : CanvasFrames()
  var begins = [Int: [Int]]()
  var ends = [Int: [Int]]()
  for (i, c) in p.clips.enumerated() where c.kind != .audio {
    let span = visibleVideo[c.id] ?? visibleArtwork[c.id] ?? (c.start..<c.end)
    begins[span.lowerBound, default: []].append(i)
    ends[span.upperBound, default: []].append(i)
  }
  let boundaries = Set(begins.keys).union(ends.keys).union([0, p.duration]).sorted()
  var active = IndexSet()
  var inst = [Slice]()
  for (start, end) in zip(boundaries, boundaries.dropFirst()) {
    for i in ends[start] ?? [] { active.remove(i) }
    for i in begins[start] ?? [] { active.insert(i) }
    let cs = active.map { p.clips[$0] }
    let maps = Dictionary(
      uniqueKeysWithValues: cs.compactMap { c in graph.sources[c.id].map { (c.id, $0) } })
    inst.append(
      Slice(
        CMTimeRange(start: time(start), duration: time(end - start)), cs, maps, graph.clock,
        painter, preview: preview, playback: playback, canvasFrames: canvasFrames, stills: graph.stills
      ))
  }
  vc.instructions = inst
  vc.customVideoCompositorClass = Compositor.self
  vc.frameDuration = time(1)
  vc.renderSize = size
  let scrubPainter = playback.map { _ in
    FramePainter(pictureProject, p.canvas.size(min(480, short)), preview: true, audioSignals: signals)
  }
  let captionOnly = !pictureProject.clips.contains { $0.kind != .audio && $0.kind != .caption }
  return Composition(graph: graph, video: vc, canvasFrames: canvasFrames, scrubPainter: scrubPainter,
                     captionOnlyPreview: captionOnly)
}

func audioSignals(in project: Project, cancelled: () -> Bool) -> [UUID: AudioSignalTrack] {
  let links = Set(project.clips.compactMap { $0.audioVisualization?.source })
  guard !links.isEmpty else { return [:] }
  var waves = [UUID: AudioWaveform]()
  var attempted = Set<UUID>()
  var pieces = [UUID: [AudioSignal]]()
  for clip in project.clips where clip.kind.isMedia && links.contains(clip.audioFamily) {
    if cancelled() { break }
    guard let asset = project.asset(clip.asset), !asset.isStill else { continue }
    if attempted.insert(asset.id).inserted {
      waves[asset.id] = AudioWaveform.cached(asset, cancelled: cancelled).wave
    }
    if let wave = waves[asset.id] {
      pieces[clip.audioFamily, default: []].append(AudioSignal(clip: clip, wave: wave))
    }
  }
  return pieces.mapValues(AudioSignalTrack.init)
}
