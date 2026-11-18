import CoreGraphics
import Foundation

let fps = 30
let maxFrames = fps * 60 * 60 * 24
func bound<T: Comparable>(_ x: T, _ low: T, _ high: T) -> T { min(max(x, low), max(low, high)) }
func tc(_ f: Int) -> String {
  let n = max(0, f)
  return String(format: "%02d:%02d:%02d", n / 1800, n / 30 % 60, n % 30)
}
enum EditError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}
enum Kind: String, Codable, CaseIterable {
  case video, audio, text, arrow, rectangle, ellipse, highlight, zoom, caption, timer
  var title: String {
    switch self {
    case .video: return "视频"
    case .audio: return "音频"
    case .text: return "文字"
    case .arrow: return "箭头"
    case .rectangle: return "矩形"
    case .ellipse: return "椭圆"
    case .highlight: return "高亮"
    case .zoom: return "局部放大"
    case .caption: return "字幕"
    case .timer: return "计时器"
    }
  }
  var icon: String {
    switch self {
    case .video: return "film"
    case .audio: return "waveform"
    case .text: return "textformat"
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .highlight: return "highlighter"
    case .zoom: return "plus.magnifyingglass"
    case .caption: return "captions.bubble"
    case .timer: return "stopwatch"
    }
  }
  var isMedia: Bool { self == .video || self == .audio }
  var isRegion: Bool { self == .highlight || self == .zoom }
  var isArt: Bool { !isMedia && self != .zoom }
}
enum Motion: String, CaseIterable, Codable {
  case none = "无"
  case shake = "摇晃"
  case slide = "滑入"
}
enum Canvas: String, CaseIterable, Codable {
  case wide = "16∶9"
  case tall = "9∶16"
  case square = "1∶1"
  func size(_ short: Int) -> CGSize {
    let long = Int((Double(short) * 16 / 9 / 2).rounded()) * 2
    switch self {
    case .wide: return CGSize(width: long, height: short)
    case .tall: return CGSize(width: short, height: long)
    case .square: return CGSize(width: short, height: short)
    }
  }
}
enum BuiltInSound: String, CaseIterable {
  case pop = "POP"
  case warning = "WARNING"
  case splash = "SPLASH"
  case meow = "MEOW"
  case shatter = "SHATTER"
  case glitch = "GLITCH"
  var frames: Int {
    switch self {
    case .pop: return 8
    case .warning: return 33
    case .splash: return 29
    case .meow: return 25
    case .shatter: return 37
    case .glitch: return 15
    }
  }
  var title: String {
    switch self {
    case .pop: return "气泡"
    case .warning: return "警报"
    case .splash: return "水花"
    case .meow: return "猫叫"
    case .shatter: return "碎裂"
    case .glitch: return "电子故障"
    }
  }
  var url: URL? { Bundle.main.url(forResource: "FX_" + rawValue, withExtension: "wav") }
}
struct Media: Identifiable, Codable, Equatable {
  var id = UUID()
  var path: String
  var frames: Int
  var video: Bool
  var audio: Bool
  var soundID: String?
  var still: Bool?
  var isStill: Bool { still == true }
  var name: String {
    soundID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }
}
enum RegionShape: String, Codable, CaseIterable {
  case rectangle = "矩形"
  case square = "方形"
  case circle = "圆形"
  func fit(_ rect: CGRect, in size: CGSize) -> CGRect {
    guard self != .rectangle else { return rect }
    let side = min(rect.width * size.width, rect.height * size.height)
    let w = side / size.width
    let h = side / size.height
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
  }
  func path(_ rect: CGRect) -> CGPath {
    self == .circle ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
  }
}
enum TransitionLook: String, Codable, CaseIterable {
  case slide = "模糊滑动"
  case flip = "模糊翻转"
  case zoom = "模糊动感放大"
  case dissolve = "叠化"
  case warp = "变焦扭曲"
  case glitch = "幻彩故障"
  case comparison = "前后对比"
  case fire = "火焰特效"
  case shake = "剧烈摇晃"
}
enum ClipEnd: String, Codable, CaseIterable {
  case head = "首端"
  case tail = "末端"
}
struct EdgeTarget: Hashable {
  let clipID: UUID
  let end: ClipEnd
}
struct ClipEdgeEffect: Codable, Equatable {
  let style: TransitionLook
  let frames: Int
}
enum FootageFilter: String, Codable, CaseIterable {
  case none = "无"
  case camera = "摄像机拍摄"
  case vhs = "VHS"
  case neon = "TikTok 式霓虹"
  case prism = "色差放射"
}
struct ClipFilter: Codable, Equatable {
  var look: FootageFilter
  var amount = 1.0
  var valid: Bool { look != .none && (0...1).contains(amount) }
}
struct SourceCrop: Codable, Equatable {
  var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
  var rect: CGRect { CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom) }
  var valid: Bool {
    [left, top, right, bottom].allSatisfy { (0...0.98).contains($0) }
      && left + right <= 0.98 + 1e-9 && top + bottom <= 0.98 + 1e-9
  }

}
struct VisualBorder: Codable, Equatable {
  var style = CaptionBorder.none
  var width = 5.0
  var color = "#FFFFFF"
  var valid: Bool { (1...64).contains(width) }
}
struct TextAppearance: Codable, Equatable {
  var font = "", bold = true
  var size = 52.0
  var outline = VisualBorder(width: 3, color: "#10141D")
  var valid: Bool { (8...240).contains(size) && outline.valid }
}
enum TimerDirection: String, Codable, CaseIterable {
  case up = "正计时"
  case down = "倒计时"
  case custom = "自定义流速"
}
enum TimerFormat: String, Codable, CaseIterable {
  case minutes = "分:秒"
  case hours = "时:分:秒"
  case seconds = "秒数"
  case decimal = "秒数（1 位小数）"
}
struct TimerSettings: Codable, Equatable {
  var direction = TimerDirection.up
  var format = TimerFormat.minutes
  var initialSeconds = 0.0
  var speed = 1.0
  var prefix = "", suffix = ""
  var valid: Bool { (0...86400).contains(initialSeconds) && (-100...100).contains(speed) }
  var signedRate: Double {
    switch direction {
    case .up: return 1
    case .down: return -1
    case .custom: return speed
    }
  }
  func display(frames: Int) -> String {
    let rate = signedRate
    let value = max(0, initialSeconds + Double(frames) / Double(fps) * rate)
    let whole = Int(rate < 0 ? ceil(value - 1e-8) : floor(value + 1e-8))
    let rendered: String
    switch format {
    case .minutes: rendered = String(format: "%02d:%02d", whole / 60, whole % 60)
    case .hours:
      rendered = String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    case .seconds: rendered = String(whole)
    case .decimal:
      let tenths = Int(rate < 0 ? ceil(value * 10 - 1e-8) : floor(value * 10 + 1e-8))
      rendered = String(format: "%.1f", Double(tenths) / 10)
    }
    return prefix + rendered + suffix
  }
}
// Positions and crop coordinates are measured in the oriented source before rotation.
struct VisualGeometry {
  let full: CGRect
  let visible: CGRect
  init(clip: Clip, canvas: CGSize, aspect: Double) {
    let width = min(canvas.width, canvas.height * aspect) * clip.displayScale
    let height = width / aspect
    full = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    let crop = (clip.sourceCrop ?? SourceCrop()).rect
    visible = CGRect(
      x: full.minX + crop.minX * width, y: full.minY + crop.minY * height,
      width: crop.width * width, height: crop.height * height)
  }
}
struct Clip: Identifiable, Codable, Equatable {
  var id = UUID()
  var kind: Kind
  var asset: UUID? = nil
  var start: Int
  var length: Int
  var offset = 0
  var sourceFraction: Double?
  var sourceSpan: Double?
  var speed: Double?
  var pitchSemitones: Double?
  var visualScale: Double?
  var sourceCrop: SourceCrop?
  var visualBorder: VisualBorder?
  var footageFilter: FootageFilter?
  var filterAmount: Double?
  var filterStack: [ClipFilter]?
  var textAppearance: TextAppearance?
  var timerSettings: TimerSettings?
  var timerPhase: Int?
  var displayScale: Double { visualScale ?? 1 }
  var filters: [ClipFilter] {
    get {
      if let filterStack { return filterStack }
      guard let footageFilter, footageFilter != .none else { return [] }
      return [ClipFilter(look: footageFilter, amount: filterAmount ?? 1)]
    }
    set {
      filterStack = newValue.isEmpty ? nil : newValue
      footageFilter = nil
      filterAmount = nil
    }
  }
  func displayedText(at frame: Int) -> String {
    kind == .timer
      ? (timerSettings ?? TimerSettings()).display(frames: frame - start + (timerPhase ?? 0)) : text
  }
  func sameSource(as other: Clip) -> Bool {
    id == other.id && asset == other.asset && kind == other.kind
      && start == other.start && length == other.length && sourceIn == other.sourceIn
      && sourceLength == other.sourceLength && volume == other.volume && pitch == other.pitch
      && from == other.from && fixedCutOffset == other.fixedCutOffset && blend == other.blend
  }
  var sourceIn: Double { Double(offset) + (sourceFraction ?? 0) }
  var sourceLength: Double { sourceSpan ?? Double(length) }
  var effectiveRate: Double { sourceLength / Double(length) }
  var rate: Double { speed ?? 1 }
  var pitch: Double { pitchSemitones ?? 0 }
  var sourceEnd: Double { sourceIn + sourceLength }
  func sourceFrame(at timelineFrame: Int) -> Double {
    sourceIn + Double(timelineFrame - start) * effectiveRate
  }
  // Preserve fractional source time and per-clip styling across a partition.
  func segment(_ range: Range<Int>, timedSource: Bool) -> Clip {
    var piece = self
    piece.start = range.lowerBound
    piece.length = range.count
    if kind.isMedia && timedSource {
      piece.setSource(sourceFrame(at: range.lowerBound), sourceFrame(at: range.upperBound))
    }
    if range.upperBound != end { piece.endEffect = nil }
    if range.lowerBound != start {
      piece.startEffect = nil
      piece.id = UUID()
      if kind == .timer { piece.timerPhase = (timerPhase ?? 0) + range.lowerBound - start }
      piece.from = nil
      piece.fixedCutOffset = nil
      piece.transitionFollowers = nil
      piece.transitionLook = nil
    }
    return piece
  }
  mutating func setSource(_ lower: Double, _ upper: Double) {
    let first = max(0, lower)
    offset = Int(floor(first))
    sourceFraction = first == Double(offset) ? nil : first - Double(offset)
    let span = upper - first
    sourceSpan = abs(span - Double(length)) < 1e-9 ? nil : span
  }
  mutating func retime(_ newRate: Double) throws {
    guard kind.isMedia, (0.25...4).contains(newRate) else {
      throw EditError.message("倍速范围为 0.25 至 4。")
    }
    let span = sourceLength
    let count = max(1, Int((span / newRate).rounded()))
    guard count <= maxFrames - start else { throw EditError.message("片段变速后会超出工程时长上限。") }
    length = count
    speed = newRate == 1 ? nil : newRate
    setSource(sourceIn, sourceIn + span)
  }
  func maximumLength(assetFrames: Int) -> Int {
    guard kind.isMedia else { return maxFrames - start }
    return min(
      maxFrames - start,
      max(length, Int(floor((Double(assetFrames) - sourceIn) / effectiveRate + 1e-8))))
  }
  var text = ""
  var x = 0.5
  var y = 0.5
  var w = 0.32
  var h = 0.14
  var angle = 0.0
  var opacity = 1.0
  var color = "#FFD465"
  var regionShape: RegionShape?
  var borderColor: String?
  var shape: RegionShape { regionShape ?? .rectangle }
  var border: String { borderColor ?? "#FFFFFF" }
  var volume = 1.0
  var scale = 1.65
  var zoomInFrames: Int?
  var zoomOutFrames: Int?
  var entryFrames: Int { zoomInFrames ?? 9 }
  var exitFrames: Int { zoomOutFrames ?? 9 }

  // Endpoint samples coincide with the unmodified scene. A short clip shares its
  // available intervals between both ramps, keeping the requested timing ratio.
  func zoomAmount(at frame: Int) -> Double {
    let local = frame - start
    guard local >= 0, local < length else { return 0 }
    let span = length - 1
    var entry = entryFrames
    var exit = exitFrames
    if entry + exit > span {
      if span < 2 && entry > 0 && exit > 0 { return 0 }
      if entry == 0 {
        exit = span
      } else if exit == 0 {
        entry = span
      } else {
        entry = bound(
          Int((Double(span) * Double(entry) / Double(entry + exit)).rounded()), 1, span - 1)
        exit = span - entry
      }
    }
    if span == 0 { return entryFrames + exitFrames == 0 ? 1 : 0 }
    let up = entry == 0 ? 1.0 : Double(local) / Double(entry)
    let down = exit == 0 ? 1.0 : Double(span - local) / Double(exit)
    let t = min(1.0, min(up, down))
    return t * t * (3 - 2 * t)
  }
  var motion = Motion.none
  var motionFrames = 15
  var motionContinuous: Bool?
  var slideFrames: Int?
  var entranceFrames: Int { slideFrames ?? (motion == .slide ? motionFrames : 0) }
  var supportsMotion: Bool { kind == .video || (kind.isArt && !kind.isRegion) }
  mutating func setSlide(_ frames: Int) {
    if motion == .slide { motion = .none }
    slideFrames = frames
  }
  func motionOffset(at frame: Int, size: CGSize) -> CGPoint {
    let age = Double(max(0, frame - start))
    var result = CGPoint.zero
    if entranceFrames > 0 {
      let t = min(1, age / Double(entranceFrames))
      result.x = size.width * (t * t * (3 - 2 * t) - 1)
    }
    if motion == .shake {
      let t = age / Double(max(1, motionFrames))
      let amplitude = motionContinuous == true ? 1 : max(0, 1 - t)
      result.x += sin(t * .pi * 8) * size.width * 0.018 * amplitude
      result.y += sin(t * .pi * 10) * size.height * 0.012 * amplitude
    }
    return result
  }
  var from: UUID? = nil
  var transitionFollowers: [UUID]?
  var transitionLook: TransitionLook?
  var startEffect: ClipEdgeEffect?
  var endEffect: ClipEdgeEffect?
  func effect(at side: ClipEnd) -> ClipEdgeEffect? { side == .head ? startEffect : endEffect }

  func transitionRange(at side: ClipEnd) -> Range<Int>? {
    guard kind == .video && length >= 2, let own = effect(at: side) else { return nil }
    var n = min(own.frames, length)
    if let a = startEffect, let b = endEffect, a.frames + b.frames > length {
      if length < 4 { return side == .head ? (start..<end) : nil }
      let desired = Int((Double(length * a.frames) / Double(a.frames + b.frames)).rounded())
      let headFrames = bound(desired, 2, length - 2)
      n = side == .head ? headFrames : length - headFrames
    }
    return side == .head ? (start..<start + n) : (end - n..<end)
  }
  var transitionStyle: TransitionLook { transitionLook ?? .slide }
  var fixedCutOffset: Int?
  var blendStart: Int { start + (fixedCutOffset.map { $0 - blend / 2 } ?? 0) }
  var blend = 15
  var end: Int { start + length }
  var region: CGRect {
    let width = bound(w, 0.01, 1)
    let height = bound(h, 0.01, 1)
    return CGRect(
      x: bound(x - width / 2, 0, 1 - width), y: bound(y - height / 2, 0, 1 - height), width: width,
      height: height)
  }
  mutating func setRegion(_ rect: CGRect) {
    x = rect.midX
    y = rect.midY
    w = rect.width
    h = rect.height
  }
  static func annotation(_ k: Kind, at f: Int) -> Clip {
    var c = Clip(kind: k, start: f, length: 90)
    switch k {
    case .text:
      c.text = "文字"
      c.color = "#FFFFFF"
      c.w = 0.6
      c.h = 0.10
    case .timer:
      c.timerSettings = TimerSettings()
      c.textAppearance = TextAppearance()
      c.color = "#FFFFFF"
      c.w = 0.7
      c.h = 0.13
      c.length = 300
    case .caption:
      c.text = "字幕"
      c.y = 0.87
      c.w = 0.84
      c.h = 0.085
      c.color = "#FFFFFF"
    case .arrow:
      c.w = 0.30
      c.h = 0.08
      c.angle = -22
    case .highlight:
      c.w = 0.35
      c.h = 0.12
      c.opacity = 0.62
    case .rectangle, .ellipse:
      c.color = "#85CEF3"
      c.h = 0.25
    case .zoom:
      c.length = 60
      c.scale = 2
      c.w = 0.36
      c.h = 0.36
    default: break
    }
    return c
  }
}
enum CaptionBorder: String, Codable, CaseIterable {
  case none = "无"
  case solid = "实线"
  case dashed = "虚线"
}
struct CaptionStyle: Codable, Equatable {
  var font = "", bold = true, fontSize = 52.0
  var foreground = "#FFFFFF", outline = "#10141D", outlineWidth = 0.0
  var background = "#111827", backgroundOpacity = 0.82, radius = 7.0
  var border = CaptionBorder.none, borderColor = "#FFFFFF", borderWidth = 2.0
  var valid: Bool {
    (12...180).contains(fontSize) && (0...16).contains(outlineWidth)
      && (0...1).contains(backgroundOpacity) && (0...60).contains(radius)
      && (1...16).contains(borderWidth)
  }
}
struct CaptionPreset: Identifiable, Codable, Equatable {
  var id = UUID()
  var name: String
  var style: CaptionStyle
  init(name: String, style: CaptionStyle) {
    self.name = name
    self.style = style
  }
}
struct Project: Codable, Equatable {
  var captionStyle: CaptionStyle?
  var backgroundColor: String?
  var background: String { backgroundColor ?? "#000000" }
  var version = 1
  var canvas = Canvas.wide
  var assets: [Media] = []
  var clips: [Clip] = []
  var duration: Int { clips.map(\.end).max() ?? 0 }
  func asset(_ id: UUID?) -> Media? { assets.first { $0.id == id } }
  func name(_ c: Clip) -> String {
    if c.kind.isMedia { return asset(c.asset)?.name ?? c.kind.title }
    return c.text.isEmpty ? c.kind.title : c.text
  }
  func checked() throws -> Project {
    guard version == 1, Set(assets.map(\.id)).count == assets.count,
      Set(clips.map(\.id)).count == clips.count
    else { throw EditError.message("工程版本或素材编号无效。") }
    if let style = captionStyle, !style.valid { throw EditError.message("字幕样式超出范围。") }
    for a in assets {
      guard a.frames > 0, a.frames <= maxFrames, a.path.hasPrefix("/") else {
        throw EditError.message("工程素材记录无效。")
      }
    }
    for c in clips {
      guard (0..<maxFrames).contains(c.start), (1...maxFrames - c.start).contains(c.length),
        (0...maxFrames).contains(c.offset),
        (c.kind == .video ? -4.0...5.0 : 0...1).contains(c.x),
        (c.kind == .video ? -4.0...5.0 : 0...1).contains(c.y),
        (0.01...2).contains(c.w), (0.01...2).contains(c.h), (0...1).contains(c.opacity),
        (0...3).contains(c.volume), (1...5).contains(c.scale), (-360...360).contains(c.angle),
        (0...maxFrames).contains(c.entryFrames), (0...maxFrames).contains(c.exitFrames),
        (0...300).contains(c.entranceFrames), (1...300).contains(c.motionFrames),
        (0.05...8).contains(c.displayScale), (0...1).contains(c.filterAmount ?? 1),
        c.filters.allSatisfy(\.valid),
        c.sourceCrop?.valid != false, c.visualBorder?.valid != false,
        c.textAppearance?.valid != false, c.timerSettings?.valid != false,
        (-maxFrames...2 * maxFrames).contains(c.timerPhase ?? 0),
        [c.startEffect, c.endEffect].compactMap { $0 }.allSatisfy { (2...90).contains($0.frames) },
        (0...90).contains(c.blend), (0...maxFrames).contains(c.fixedCutOffset ?? 0)
      else { throw EditError.message("片段的时间或属性超出范围。") }
      if c.kind.isMedia {
        guard let a = asset(c.asset), (0.25...4).contains(c.rate), (-12...12).contains(c.pitch),
          (0..<1.0).contains(c.sourceFraction ?? 0), c.sourceLength > 0,
          a.isStill || c.sourceEnd <= Double(a.frames) + 1e-7,
          c.kind == .video ? a.video : a.audio
        else { throw EditError.message("素材与片段不匹配。") }
      }
    }
    return self
  }
  mutating func cut(_ id: UUID, at frame: Int) -> UUID? {
    guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].start < frame,
      frame < clips[i].end
    else { return nil }
    let original = clips[i]
    let timedSource = asset(original.asset)?.isStill != true
    let r = original.segment(frame..<original.end, timedSource: timedSource)
    clips[i] = original.segment(original.start..<frame, timedSource: timedSource)
    clips.insert(r, at: i + 1)
    for j in clips.indices where clips[j].from == id && clips[j].start >= frame {
      clips[j].from = r.id
    }
    for j in clips.indices where clips[j].transitionFollowers?.contains(id) == true {
      clips[j].transitionFollowers?.append(r.id)
    }
    return r.id
  }
  // Remove the same interval on every track so captions and audio stay in sync.
  mutating func deleteInterval(_ start: Int, _ end: Int) {
    guard start >= 0, end > start else { return }
    for boundary in [start, end] {
      let crossing = clips.filter { $0.start < boundary && $0.end > boundary }.map(\.id)
      for id in crossing { _ = cut(id, at: boundary) }
    }
    clips.removeAll { $0.start >= start && $0.end <= end }
    let remaining = Set(clips.map(\.id))
    for i in clips.indices {
      if clips[i].start >= end { clips[i].start -= end - start }
      if let id = clips[i].from, !remaining.contains(id) { clips[i].from = nil }
    }
  }
  static func read(from url: URL) throws -> Project {
    var p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    for i in p.assets.indices {
      if let sound = p.assets[i].soundID {
        guard let u = BuiltInSound(rawValue: sound)?.url else {
          throw EditError.message("找不到内置音效「" + sound + "」。")
        }
        p.assets[i].path = u.path
        continue
      }
      if p.assets[i].path.hasPrefix("/") { continue }
      p.assets[i].path =
        url.deletingLastPathComponent().appendingPathComponent(p.assets[i].path).standardizedFileURL
        .path
    }
    return try p.checked()
  }
  func write(to url: URL) throws {
    var copy = self
    let folder = url.deletingLastPathComponent().standardizedFileURL.path + "/"
    for i in copy.assets.indices where copy.assets[i].path.hasPrefix(folder) {
      copy.assets[i].path = String(copy.assets[i].path.dropFirst(folder.count))
    }
    for i in copy.assets.indices {
      if let sound = copy.assets[i].soundID { copy.assets[i].path = "Sounds/" + sound + ".wav" }
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(copy).write(to: url, options: .atomic)
  }
  struct Join: Identifiable {
    let before: Clip, after: Clip
    var id: UUID { after.id }
    var active: Bool {
      after.from == before.id && after.blend > 0
        && (after.fixedCutOffset != nil || after.start < before.end)
    }
    var range: Range<Int> {
      if !active { return frame..<frame }
      if after.fixedCutOffset != nil {
        let start = max(before.start, frame - after.blend / 2)
        return start..<min(after.end, start + after.blend)
      }
      return after.start..<min(before.end, after.start + after.blend)
    }
    var frame: Int {
      if let offset = after.fixedCutOffset, after.from == before.id {
        return bound(
          after.start + offset, after.start, max(after.start, min(before.end, after.end - 1)))
      }
      return active ? after.start + min(after.blend, before.end - after.start) / 2 : before.end
    }
  }
  var joins: [Join] {
    let videos = clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
    let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
    let ending = Dictionary(grouping: videos, by: \.end)
    return videos.compactMap { next in
      let explicit = next.from.flatMap { byID[$0] }
      let left =
        explicit.flatMap { $0.start < next.start && $0.end > next.start ? $0 : nil }
        ?? ending[next.start]?.last
      guard let left, left.length >= 3, next.length >= 3 else { return nil }
      return Join(before: left, after: next)
    }
  }
  // A connected chain occupies one editing lane over its combined time range.
  // Unrelated overlapping video remains independently selectable on another lane.
  func videoLanes(_ joins: [Join]) -> [[Clip]] {
    let clips = self.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
    let heads = Dictionary(uniqueKeysWithValues: joins.map { ($0.after.id, $0.before.id) })
    var chains = [[Clip]]()
    var indices = [UUID: Int]()
    for c in clips {
      if let before = heads[c.id], let i = indices[before], chains[i].last?.id == before {
        chains[i].append(c)
        indices[c.id] = i
      } else {
        indices[c.id] = chains.count
        chains.append([c])
      }
    }
    var rows = [[Clip]]()
    var ends = [Int]()
    for chain in chains {
      let finish = chain.map(\.end).max()!
      if let i = ends.firstIndex(where: { $0 <= chain[0].start }) {
        rows[i] += chain
        ends[i] = finish
      } else {
        rows.append(chain)
        ends.append(finish)
      }
    }
    return rows.isEmpty ? [[]] : rows
  }
  var videoVisibility: [UUID: Range<Int>] {
    var spans = Dictionary(
      uniqueKeysWithValues: clips.filter { $0.kind == .video }.map { ($0.id, $0.start..<$0.end) })
    for j in joins where j.after.from == j.before.id && j.after.fixedCutOffset != nil {
      let cut = j.range
      guard let left = spans[j.before.id], let right = spans[j.after.id],
        left.lowerBound < cut.upperBound, cut.lowerBound < right.upperBound
      else { continue }
      spans[j.before.id] = left.lowerBound..<cut.upperBound
      spans[j.after.id] = cut.lowerBound..<right.upperBound
    }
    return spans
  }
  mutating func setEdgeEffect(_ target: EdgeTarget, frames: Int, style: TransitionLook?) throws {
    guard let index = clips.firstIndex(where: { $0.id == target.clipID }),
      clips[index].kind == .video
    else { throw EditError.message("请选择图片或视频片段的首端或末端。") }
    let c = clips[index]
    let other = c.effect(at: target.end == .head ? .tail : .head)
    let available = c.length - (other == nil ? 0 : min(c.length - 2, other!.frames))
    if frames > 0 && (c.length < 2 || (other != nil && c.length < 4)) {
      throw EditError.message("片段太短，请先延长片段或移除另一端的转场。")
    }
    let next =
      frames <= 0
      ? nil
      : ClipEdgeEffect(
        style: style ?? c.effect(at: target.end)?.style ?? .slide,
        frames: bound(frames, 2, min(90, available)))
    if target.end == .head {
      clips[index].startEffect = next
    } else {
      clips[index].endEffect = next
    }
  }

  mutating func setTransition(_ id: UUID, frames: Int, style: TransitionLook? = nil) throws {
    guard let join = joins.first(where: { $0.id == id }),
      let i = clips.firstIndex(where: { $0.id == id })
    else { throw EditError.message("请先让两个视频片段首尾相接。") }
    let cut = join.frame
    let links = joins
    let previous = links.first { $0.id == join.before.id }?.frame ?? join.before.start
    let next = links.first { $0.before.id == id }?.frame ?? join.after.end
    let available = min(cut - previous, next - cut)
    let n = frames == 0 ? 0 : min(90, max(2, frames), available)
    guard frames == 0 || n >= 2 else { throw EditError.message("这两个片段没有足够长度添加转场。") }
    // Keep the authored media and all other tracks fixed. Retain the cut location
    // when disabling a legacy overlap so the existing edit becomes a hard cut.
    let keepLink = n > 0 || join.before.end > join.after.start
    clips[i].from = keepLink ? join.before.id : nil
    clips[i].fixedCutOffset = keepLink ? cut - join.after.start : nil
    clips[i].transitionFollowers = nil
    clips[i].blend = n
    let look = style ?? join.after.transitionStyle
    clips[i].transitionLook = n > 0 && look != .slide ? look : nil
  }

}
enum SRT {
  static func parse(_ raw: String) throws -> [Clip] {
    let text = raw.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(
      of: "\r\n", with: "\n"
    ).replacingOccurrences(of: "\r", with: "\n")
    let blocks = text.components(separatedBy: "\n\n")
    func frame(_ s: Substring) -> Int? {
      let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        .components(separatedBy: CharacterSet(charactersIn: ":,"))
      guard p.count == 4, p[3].count == 3, let h = Int(p[0]), let m = Int(p[1]),
        let sec = Int(p[2]), let ms = Int(p[3]), (0...24).contains(h), (0..<60).contains(m),
        (0..<60).contains(sec), (0..<1000).contains(ms)
      else { return nil }
      return Int((Double((h * 3600 + m * 60 + sec) * 1000 + ms) * 0.03).rounded())
    }
    var result = [Clip]()
    for b in blocks where !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let lines = b.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
      guard let t = lines.firstIndex(where: { $0.contains("-->") }), t + 1 < lines.count else {
        throw EditError.message("第 \(result.count+1) 条字幕缺少时间码或正文。")
      }
      let pair = lines[t].components(separatedBy: "-->")
      guard pair.count == 2, let start = frame(pair[0][...]), let end = frame(pair[1][...]),
        end > start, end <= maxFrames
      else { throw EditError.message("第 \(result.count+1) 条字幕时间码无效。") }
      var c = Clip.annotation(.caption, at: start)
      c.length = end - start
      c.text = lines[(t + 1)...].joined(separator: "\n")
      result.append(c)
    }
    guard !result.isEmpty else { throw EditError.message("字幕文件为空。") }
    return result
  }
  static func write(_ clips: [Clip]) -> String {
    func stamp(_ f: Int) -> String {
      let v = Int((Double(f) * 1000 / 30).rounded())
      return String(
        format: "%02d:%02d:%02d,%03d", v / 3_600_000, v / 60000 % 60, v / 1000 % 60, v % 1000)
    }
    return clips.filter { $0.kind == .caption }.sorted { $0.start < $1.start }.enumerated().map {
      i, c in "\(i+1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
    }.joined(separator: "\n")
  }
}
