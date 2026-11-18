import AVFoundation
import AppKit
import UniformTypeIdentifiers
import VideoToolbox

func time(_ f: Int) -> CMTime { CMTime(value: Int64(f), timescale: 30) }
struct SourceMap {
  let track: CMPersistentTrackID
  let transform: CGAffineTransform
}
final class Slice: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false, containsTweening = true
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let requiredSourceTrackIDs: [NSValue]?
  let preview: Bool
  let stills: [UUID: URL]
  let painter: FramePainter, clips: [Clip], sources: [UUID: SourceMap]
  init(
    _ range: CMTimeRange, _ clips: [Clip], _ sources: [UUID: SourceMap],
    _ clock: CMPersistentTrackID, _ painter: FramePainter, preview: Bool, stills: [UUID: URL]
  ) {
    self.preview = preview
    self.stills = stills
    timeRange = range
    self.clips = clips
    self.sources = sources
    self.painter = painter
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
  private let scaler = PreviewScaler()
  let sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ]
  let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ]
  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    #if FRAME_BENCH
      let start = CFAbsoluteTimeGetCurrent()
      defer {
        RenderStatistics.record(
          Int((request.compositionTime.seconds * 30).rounded()),
          1000 * (CFAbsoluteTimeGetCurrent() - start))
      }
    #endif
    autoreleasepool {
      guard let s = request.videoCompositionInstruction as? Slice,
        let out = request.renderContext.newPixelBuffer()
      else {
        request.finish(with: EditError.message("无法分配预览画面。"))
        return
      }
      CVPixelBufferLockBaseAddress(out, [])
      guard
        let g = bitmap(
          CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out),
          data: CVPixelBufferGetBaseAddress(out), row: CVPixelBufferGetBytesPerRow(out))
      else {
        CVPixelBufferUnlockBaseAddress(out, [])
        request.finish(with: EditError.message("无法创建画布。"))
        return
      }
      // AVFoundation may change the backing size for a render context.
      g.scaleBy(
        x: CGFloat(CVPixelBufferGetWidth(out)) / s.painter.size.width,
        y: CGFloat(CVPixelBufferGetHeight(out)) / s.painter.size.height)
      s.painter.paint(
        g, frame: Int((request.compositionTime.seconds * 30).rounded()), active: s.clips
      ) { id, canvas in
        if let url = s.stills[id], let im = StillImages.image(url, limit: s.preview ? 2160 : 4096) {
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
      g.flush()
      CVPixelBufferUnlockBaseAddress(out, [])
      request.finish(withComposedVideoFrame: out)
    }
  }
}
struct MediaGraph {
  let asset: AVMutableComposition, audio: AVMutableAudioMix
  let sources: [UUID: SourceMap], clock: CMPersistentTrackID
  let pitchFiles: [PitchedAudio]
  let stills: [UUID: URL]
}
private var audioLeaseKey: UInt8 = 0
struct Composition {
  let graph: MediaGraph, video: AVMutableVideoComposition
  var asset: AVMutableComposition { graph.asset }
  var audio: AVMutableAudioMix { graph.audio }
  func retainAudio(on object: AnyObject) {
    if !graph.pitchFiles.isEmpty {
      objc_setAssociatedObject(
        object, &audioLeaseKey, graph.pitchFiles, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
  func item() -> AVPlayerItem {
    let i = AVPlayerItem(asset: asset)
    i.videoComposition = video
    i.audioMix = audio
    i.audioTimePitchAlgorithm = .spectral
    retainAudio(on: i)
    return i
  }
}
private func sourceTime(_ frame: Double) -> CMTime {
  CMTime(value: Int64((frame * 20000).rounded()), timescale: 600000)
}
func clockURL() throws -> URL {
  guard let u = Bundle.main.url(forResource: "Clock", withExtension: "mp4") else {
    throw EditError.message("应用缺少 Clock.mp4 资源。")
  }
  return u
}
func inspect(_ u: URL) throws -> Media {
  if (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true,
    StillImages.dimensions(u) != nil, StillImages.image(u, limit: 160) != nil
  {
    return Media(
      path: u.standardizedFileURL.path, frames: 150, video: true, audio: false, still: true)
  }
  let a = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
  let v = !a.tracks(withMediaType: .video).isEmpty
  let s = !a.tracks(withMediaType: .audio).isEmpty
  let sec = a.duration.seconds
  guard a.isPlayable, sec.isFinite, sec >= 1.0 / 30, sec <= 86400, v || s else {
    throw EditError.message("无法读取「\(u.lastPathComponent)」。请使用系统可解码的图片、视频或音频文件。")
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
  if visible.lowerBound < clip.start { try hold(from: available.start, at: start, duration: lead) }
  try lane.insertTimeRange(core, of: source, at: start + lead)
  if core.duration != coreDuration {
    lane.scaleTimeRange(
      CMTimeRange(start: start + lead, duration: core.duration), toDuration: coreDuration)
  }
  if visible.upperBound > clip.end {
    try hold(
      from: available.end, at: start + lead + coreDuration, duration: length - lead - coreDuration)
  }
}
func buildMediaGraph(_ p: Project, cancelled: () -> Bool) throws -> MediaGraph {
  guard p.duration > 0 else { throw EditError.message("时间线上还没有片段。") }
  let a = AVMutableComposition()
  var pitchFiles = [PitchedAudio]()
  let mix = AVMutableAudioMix()
  let base = AVURLAsset(url: try clockURL())
  guard let track = base.tracks(withMediaType: .video).first,
    let clk = a.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
  else { throw EditError.message("无法建立预览轨道。") }
  try clk.insertTimeRange(track.timeRange, of: track, at: .zero)
  clk.scaleTimeRange(track.timeRange, toDuration: time(p.duration))
  let visibleVideo = p.videoVisibility
  var sources = [UUID: SourceMap]()
  var stills = [UUID: URL]()
  var checkedStills = Set<UUID>()
  var assets = [UUID: AVURLAsset]()
  var pools = [AVMediaType: [(AVMutableCompositionTrack, Int)]]()
  var volumes = [CMPersistentTrackID: AVMutableAudioMixInputParameters]()
  for c in p.clips.sorted(by: { $0.start < $1.start }) where c.kind.isMedia {
    if cancelled() { throw EditError.message("预览更新已替换。") }
    guard let media = p.asset(c.asset), FileManager.default.fileExists(atPath: media.path) else {
      throw EditError.message("找不到「\(p.name(c))」。请在素材列表中重新定位文件。")
    }
    if media.isStill {
      let url = URL(fileURLWithPath: media.path)
      if checkedStills.insert(media.id).inserted, StillImages.dimensions(url) == nil {
        throw EditError.message("无法读取图片「" + media.name + "」。")
      }
      stills[c.id] = url
      continue
    }
    let src =
      assets[media.id]
      ?? AVURLAsset(
        url: URL(fileURLWithPath: media.path),
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    assets[media.id] = src
    var types = [AVMediaType]()
    if c.kind == .video { types.append(.video) }
    if media.audio && c.volume > 0 { types.append(.audio) }
    for type in types {
      guard let original = src.tracks(withMediaType: type).first else {
        throw EditError.message("无法读取「\(media.name)」的轨道。")
      }
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
        else { throw EditError.message("轨道数量超出系统限制。") }
        lane = t
        lanes.append((t, span.upperBound))
      }
      pools[type] = lanes
      if type == .video {
        try insertVideo(c, visible: span, source: original, into: lane)
        sources[c.id] = SourceMap(track: lane.trackID, transform: original.preferredTransform)
      } else {
        let start =
          time(c.start)
          + CMTimeMultiplyByFloat64(range.start - desired.start, multiplier: 1 / c.effectiveRate)
        let duration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / c.effectiveRate)
        let input: AVAssetTrack
        let inputRange: CMTimeRange
        if c.pitch != 0 {
          let file = try PitchedAudio.make(
            src, track: original, range: range, semitones: c.pitch, cancelled: cancelled)
          pitchFiles.append(file)
          let pitchedAsset = file.readable
          guard let t = pitchedAsset.tracks(withMediaType: .audio).first else {
            throw EditError.message("无法读取变调后的音轨。")
          }
          input = t
          inputRange = t.timeRange
        } else {
          input = original
          inputRange = range
        }
        do { try lane.insertTimeRange(inputRange, of: input, at: start) } catch {
          throw EditError.message("无法合成「" + media.name + "」的音轨。" + error.localizedDescription)
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
    asset: a, audio: mix, sources: sources, clock: clk.trackID, pitchFiles: pitchFiles,
    stills: stills)
}
func buildComposition(
  _ p: Project, short: Int, preview: Bool = false, reusing existing: MediaGraph? = nil,
  cancelled: () -> Bool = { false }
) throws -> Composition {
  let graph = try existing ?? buildMediaGraph(p, cancelled: cancelled)
  let visibleVideo = p.videoVisibility
  let vc = AVMutableVideoComposition()
  let size = p.canvas.size(short)
  let painter = FramePainter(p, size, preview: preview)
  var begins = [Int: [Int]]()
  var ends = [Int: [Int]]()
  for (i, c) in p.clips.enumerated() where c.kind != .audio {
    let span = visibleVideo[c.id] ?? (c.start..<c.end)
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
        painter, preview: preview, stills: graph.stills
      ))
  }
  vc.instructions = inst
  vc.customVideoCompositorClass = Compositor.self
  vc.frameDuration = time(1)
  vc.renderSize = size
  return Composition(graph: graph, video: vc)
}
