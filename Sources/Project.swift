import CoreGraphics
import Foundation

let fps = 30
let maxFrames = fps * 60 * 60 * 24
func bound<T: Comparable>(_ x: T, _ low: T, _ high: T) -> T { min(max(x, low), max(low, high)) }
func tc(_ f: Int) -> String {
  let n = max(0, f)
  return String(format: "%02d:%02d:%02d", n / 1800, n / 30 % 60, n % 30)
}

struct TimelineSnap {
  let anchors: [Int]
  let limits: ClosedRange<Int>
  private let targets: [Int]

  init(anchors: [Int], targets: [Int], limits: ClosedRange<Int>) {
    self.anchors = anchors
    self.targets = Set(targets).sorted()
    self.limits = limits
  }

  func placement(for requested: Double, per: Double) -> (shift: Int, guide: Int?) {
    let low = Double(limits.lowerBound), high = Double(limits.upperBound)
    let shift = Int(bound(requested, low, high).rounded())
    var closest: (shift: Int, guide: Int)?
    var distance = min(15, 6 / per)
    for anchor in anchors {
      let desired = Double(anchor) + requested
      let index = insertionIndex(Double(anchor) + bound(requested, low, high))
      for i in [index - 1, index] where targets.indices.contains(i) {
        let target = targets[i]
        let offset = target - anchor
        let gap = abs(Double(target) - desired)
        if limits.contains(offset) && gap <= distance && (closest == nil || gap < distance) {
          closest = (offset, target)
          distance = gap
        }
      }
    }
    if let closest { return (closest.shift, closest.guide) }
    return (shift, nil)
  }

  private func insertionIndex(_ wanted: Double) -> Int {
    var low = 0, high = targets.count
    while low < high {
      let mid = (low + high) / 2
      if Double(targets[mid]) < wanted { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

enum EditError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}
enum Kind: String, Codable, CaseIterable {
  case video, audio, text, arrow, rectangle, ellipse, highlight, zoom, caption, timer, chart, editorial, audioVisual
  var title: String {
    switch self {
    case .video: return L("视频")
    case .audio: return L("音频")
    case .text: return L("文字")
    case .arrow: return L("箭头")
    case .rectangle: return L("矩形")
    case .ellipse: return L("椭圆")
    case .highlight: return L("高亮")
    case .zoom: return L("局部放大")
    case .caption: return L("字幕")
    case .timer: return L("计时器")
    case .chart: return L("图表")
    case .editorial: return L("快剪图形")
    case .audioVisual: return L("音频可视化")
    }
  }
  var icon: String {
    switch self {
    case .video: return "film"
    case .audio: return "waveform"
    case .text: return "text.alignleft"
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .highlight: return "highlighter"
    case .zoom: return "plus.magnifyingglass"
    case .caption: return "captions.bubble"
    case .timer: return "stopwatch"
    case .chart: return "chart.bar.xaxis"
    case .editorial: return "rectangle.on.rectangle"
    case .audioVisual: return "waveform.path"
    }
  }
  var isMedia: Bool { self == .video || self == .audio }
  var isRegion: Bool { self == .highlight || self == .zoom }
  var isArt: Bool { !isMedia && self != .zoom }
  var supportsArtworkTransitions: Bool {
    self == .text || self == .rectangle || self == .ellipse || self == .audioVisual
  }
  var supportsTransitions: Bool { self == .video || supportsArtworkTransitions }
  var supportsShapeAppearance: Bool { self == .rectangle || self == .ellipse }
  var supportsRelief: Bool { [.text, .timer, .rectangle, .ellipse, .arrow].contains(self) }
}
enum Motion: String, CaseIterable, Codable {
  case none = "无"
  case shake = "摇晃"
  case slide = "滑入"
  case pushIn = "拉近"
  case pullOut = "拉远"
  case path = "自定义路径"

  var isZoom: Bool { self == .pushIn || self == .pullOut }
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
  case legacyWoosh = "WOOSH"
  case woosh = "WOOSH_SHORT"
  static var library: [Self] { allCases.filter { $0 != .legacyWoosh } }
  var name: String { self == .woosh ? "WOOSH" : rawValue }
  var frames: Int {
    switch self {
    case .pop: return 8
    case .warning: return 33
    case .splash: return 29
    case .meow: return 25
    case .shatter: return 37
    case .glitch: return 15
    case .legacyWoosh: return 24
    case .woosh: return 12
    }
  }
  var title: String {
    switch self {
    case .pop: return L("气泡")
    case .warning: return L("警报")
    case .splash: return L("水花")
    case .meow: return L("猫叫")
    case .shatter: return L("碎裂")
    case .glitch: return L("电子故障")
    case .legacyWoosh, .woosh: return L("转场风声")
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
    if let soundID { return BuiltInSound(rawValue: soundID)?.name ?? soundID }
    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
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
  case unfold = "展开"
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
enum TransitionTarget: Hashable {
  case join(UUID)
  case edge(EdgeTarget)

  static func ends(of clip: Clip) -> [Self] {
    if !clip.kind.supportsTransitions || clip.length < 2 { return [] }
    let sides: [ClipEnd] = clip.length >= 4 ? [.head, .tail] : [.head]
    return sides.map { .edge(EdgeTarget(clipID: clip.id, end: $0)) }
  }

  static func cardTargets(for clips: [Clip]) -> [Self] {
    let eligible = clips.filter { $0.kind.supportsTransitions && $0.length >= 2 }
    let groups = Dictionary(grouping: eligible.filter { $0.kind == .video && $0.groupID != nil }, by: \.groupID)
    let outerEdges = groups.compactMapValues { members -> (head: UUID, tail: UUID)? in
      guard members.count > 1, let first = members.min(by: { $0.start < $1.start }),
        let last = members.max(by: { $0.end < $1.end })
      else { return nil }
      return (first.id, last.id)
    }
    return eligible.flatMap { clip -> [Self] in
      if clip.kind.supportsArtworkTransitions && groups[clip.groupID] != nil { return [] }
      guard let ends = outerEdges[clip.groupID] else { return Self.ends(of: clip) }
      if ends.head == clip.id && ends.tail == clip.id { return Self.ends(of: clip) }
      return ClipEnd.allCases.compactMap { side in
        let id = side == .head ? ends.head : ends.tail
        return id == clip.id ? .edge(EdgeTarget(clipID: id, end: side)) : nil
      }
    }
  }

  static func at(
    x: Double, first: Double, per: Double, clips: [Clip], joins: [Project.Join], bothEnds: Bool = true
  ) -> [Self] {
    let frame = first + x / per
    if let join = joins.min(by: { abs(Double($0.frame) - frame) < abs(Double($1.frame) - frame) }),
      abs(Double(join.frame) - frame) * per <= min(16, Double(min(join.before.length, join.after.length)) * per / 5)
    {
      return [.join(join.id)]
    }
    guard let clip = clips.last(where: {
      $0.kind.supportsTransitions && Double($0.start) <= frame && frame <= Double($0.end)
    }),
      clip.length >= 2
    else { return [] }
    let offset = (frame - Double(clip.start)) * per
    let width = Double(clip.length) * per
    let edgeWidth = min(52, width * 0.27)
    if offset <= edgeWidth || (clip.length < 4 && offset <= width / 2) {
      return [.edge(EdgeTarget(clipID: clip.id, end: .head))]
    }
    if width - offset <= edgeWidth || clip.length < 4 {
      return [.edge(EdgeTarget(clipID: clip.id, end: .tail))]
    }
    if !bothEnds {
      return [.edge(EdgeTarget(clipID: clip.id, end: offset < width / 2 ? .head : .tail))]
    }
    return ends(of: clip)
  }
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
  case edgeBlur = "边缘失焦"
  case backgroundKey = "去除背景"
}
struct ClipFilter: Codable, Equatable {
  var look: FootageFilter
  var amount = 1.0
  var fadeInFrames: Int?
  var fadeOutFrames: Int?
  var keySensitivity: Double?
  var keyColor: UInt32?
  var sensitivity: Double { keySensitivity ?? BackgroundKey.defaultSensitivity }
  var entryFrames: Int { fadeInFrames ?? 0 }
  var exitFrames: Int { fadeOutFrames ?? 0 }
  var valid: Bool {
    look != .none && (0...1).contains(amount)
      && (0...1).contains(sensitivity) && keyColor.map { $0 <= 0xFFFFFF } != false
      && (0...maxFrames).contains(entryFrames) && (0...maxFrames).contains(exitFrames)
  }
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
struct TextShadow: Codable, Equatable {
  var enabled = true
  var color = "#000000"
  var opacity = 0.8
  var blur = 5.0
  var x = 0.0, y = 2.0
  var valid: Bool {
    (0...1).contains(opacity) && (0...240).contains(blur)
      && (-2160...2160).contains(x) && (-2160...2160).contains(y)
  }
}
struct TextDuotone: Codable, Equatable {
  var enabled = true
  var firstColor = "#F59C50"
  var secondColor = "#FFFFFF"
  var angle = 0.0
  var position = 0.5
  var valid: Bool { (-180...180).contains(angle) && (0...1).contains(position) }
}
struct TextAppearance: Codable, Equatable {
  var font = "", bold = true
  var size = 52.0
  var outline = VisualBorder(width: 3, color: "#10141D")
  var fixedSize: Bool?
  var shadow: TextShadow?
  var duotone: TextDuotone?
  var activeDuotone: TextDuotone? { duotone?.enabled == true ? duotone : nil }
  var usesFixedSize: Bool { fixedSize == true || size > 240 }
  var valid: Bool {
    size.isFinite && size >= 8 && outline.valid && shadow?.valid != false && duotone?.valid != false
  }
}
struct TextAnimation: Codable, Equatable {
  var underline = false
  var characters = false
  var entryFrames = 12
  var exitFrames = 12
  var enabled: Bool { underline || characters }
  var valid: Bool { (0...maxFrames).contains(entryFrames) && (0...maxFrames).contains(exitFrames) }
}
enum ShapeFill: String, Codable, CaseIterable {
  case hollow, solid

  var title: String { self == .hollow ? L("空心") : L("实心") }
}
enum ShapeEdge: String, Codable, CaseIterable {
  case smooth, rough

  var title: String { self == .smooth ? L("平滑") : L("粗犷") }
}
struct ShapeAppearance: Codable, Equatable {
  var fill: ShapeFill?
  var edge = ShapeEdge.smooth
  var outlineWidth: Double?
  var roughness = 0.70
  var valid: Bool {
    (0...1).contains(roughness) && outlineWidth.map { (1...64).contains($0) } != false
  }
}
enum ReliefStyle: String, Codable, CaseIterable {
  case flat, extrusion, chrome, neon

  var title: String {
    switch self {
    case .flat: return L("平面")
    case .extrusion: return L("立体挤出")
    case .chrome: return L("镀铬")
    case .neon: return L("霓虹立体")
    }
  }
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
    let crop = (clip.sourceCrop ?? SourceCrop()).rect
    if let inset = clip.pictureInset {
      let height = min(canvas.width, canvas.height) * clip.displayScale
      let width = height * inset.shape.aspect
      visible = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
      let fullHeight = max(width / (crop.width * aspect), height / crop.height)
      let fullWidth = fullHeight * aspect
      full = CGRect(x: -crop.midX * fullWidth, y: -crop.midY * fullHeight,
                    width: fullWidth, height: fullHeight)
      return
    }
    let width = min(canvas.width, canvas.height * aspect) * clip.displayScale
    let height = width / aspect
    full = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    visible = CGRect(
      x: full.minX + crop.minX * width, y: full.minY + crop.minY * height,
      width: crop.width * width, height: crop.height * height)
  }
}
struct Clip: Identifiable, Codable, Equatable {
  var id = UUID()
  var groupID: UUID?
  var kind: Kind
  var asset: UUID? = nil
  var start: Int
  var length: Int
  var offset = 0
  var sourceFraction: Double?
  var sourceSpan: Double?
  var speed: Double?
  var pitchSemitones: Double?
  var audioLink: UUID?
  var audioVisualization: AudioVisualization?
  var visualScale: Double?
  var sourceCrop: SourceCrop?
  var visualBorder: VisualBorder?
  var pictureInset: PictureInset?
  var footageFilter: FootageFilter?
  var filterAmount: Double?
  var filterStack: [ClipFilter]?
  var textAppearance: TextAppearance?
  var textAnimation: TextAnimation?
  var chart: ChartSpec?
  var chartAppearance: ChartAppearance?
  var editorial: EditorialSpec?
  var reliefStyle: ReliefStyle?
  var relief: ReliefStyle? { reliefStyle == .flat ? nil : reliefStyle }
  var shapeAppearance: ShapeAppearance?
  var shapeFill: ShapeFill { shapeAppearance?.fill ?? (relief == nil ? .hollow : .solid) }
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
    if range != start..<end {
      piece.audioVisualization?.followsSource = false
      piece.motionPath = pathMotion(in: range)
    }
    if kind.isMedia && timedSource {
      piece.setSource(sourceFrame(at: range.lowerBound), sourceFrame(at: range.upperBound))
    }
    if range.upperBound != end { piece.endEffect = nil }
    if range.lowerBound != start {
      piece.startEffect = nil
      piece.id = UUID()
      if kind == .timer { piece.timerPhase = (timerPhase ?? 0) + range.lowerBound - start }
      piece.editorial?.shiftReveal(by: start - range.lowerBound)
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
      throw EditError.message(L("倍速范围为 0.25 至 4。"))
    }
    let span = sourceLength
    let count = max(1, Int((span / newRate).rounded()))
    guard count <= maxFrames - start else { throw EditError.message(L("片段变速后会超出工程时长上限。")) }
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
  var captionTranslation: String?
  var captionText: String {
    guard let captionTranslation, !captionTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return text }
    return text.isEmpty ? captionTranslation : text + "\n" + captionTranslation
  }
  var x = 0.5
  var y = 0.5
  var w = 0.32
  var h = 0.14
  var angle = 0.0
  var opacity = 1.0
  var color = "#FFD465"
  var regionShape: RegionShape?
  var borderColor: String?
  var lensBorderWidth: Double?
  var highlightFadeIn: Bool?
  var highlightFadeOut: Bool?
  var shape: RegionShape { regionShape ?? .rectangle }
  var border: String { borderColor ?? "#FFFFFF" }
  static let defaultLensBorderWidth = 3.78
  var volume = 1.0
  var scale = 1.65
  var zoomInFrames: Int?
  var zoomOutFrames: Int?
  var entryFrames: Int { zoomInFrames ?? 9 }
  var exitFrames: Int { zoomOutFrames ?? 9 }

  // Endpoint samples coincide with the unmodified scene. A short clip shares its
  // available intervals between both ramps, keeping the requested timing ratio.
  func zoomAmount(at frame: Int) -> Double {
    fadeAmount(at: frame, entry: entryFrames, exit: exitFrames)
  }

  func highlightOpacity(at frame: Int) -> Double {
    opacity * fadeAmount(at: frame, entry: highlightFadeIn == true ? 9 : 0,
                         exit: highlightFadeOut == true ? 9 : 0)
  }

  func textAnimationProgress(_ animation: TextAnimation, at frame: Int) -> Double {
    guard (start..<end).contains(frame) else { return 0 }
    return length <= 2 ? 1 : fadeAmount(
      at: frame, entry: animation.entryFrames, exit: animation.exitFrames, eased: false)
  }

  func filterIntensity(_ filter: ClipFilter, at frame: Int) -> Double {
    guard filter.entryFrames > 0 || filter.exitFrames > 0 else { return filter.amount }
    let sample = bound(frame, start, end - 1)
    return filter.amount * (length <= 2 ? 1
      : fadeAmount(at: sample, entry: filter.entryFrames, exit: filter.exitFrames))
  }

  private func fadeAmount(
    at frame: Int, entry requestedEntry: Int, exit requestedExit: Int, eased: Bool = true
  ) -> Double {
    let local = frame - start
    guard local >= 0, local < length else { return 0 }
    let span = length - 1
    var entry = requestedEntry
    var exit = requestedExit
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
    if span == 0 { return requestedEntry + requestedExit == 0 ? 1 : 0 }
    let up = entry == 0 ? 1.0 : Double(local) / Double(entry)
    let down = exit == 0 ? 1.0 : Double(span - local) / Double(exit)
    let t = min(1.0, min(up, down))
    return eased ? t * t * (3 - 2 * t) : t
  }
  var motion = Motion.none
  var motionFrames = 15
  var motionContinuous: Bool?
  var shakeAmplitude: Double?
  var shakeFrequency: Double?
  var motionZoom: Double?
  var motionPath: MotionPath?
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
    if motion == .path, let motionPath {
      let offset = motionPath.at(pathProgress(at: frame))
      result.x += offset.x * size.width
      result.y += offset.y * size.height
    }
    if motion == .shake {
      let t = age / Double(max(1, motionFrames))
      let envelope = motionContinuous == true ? 1 : max(0, 1 - t)
      let xPhase = shakeFrequency.map { age / Double(fps) * $0 * 2 * .pi } ?? (t * .pi * 8)
      let yPhase = shakeFrequency == nil ? t * .pi * 10 : xPhase * 1.25
      let amplitude = shakeAmplitude ?? 0.018
      result.x += sin(xPhase) * size.width * amplitude * envelope
      result.y += sin(yPhase) * size.height * (0.012 * (amplitude / 0.018)) * envelope
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
    guard kind.supportsTransitions && length >= 2, let own = effect(at: side) else { return nil }
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
      c.text = L("文字")
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
      c.text = L("字幕")
      c.y = 0.87
      c.w = 0.84
      c.h = 0.085
      c.color = "#FFFFFF"
    case .arrow:
      c.w = 0.30
      c.h = 0.08
      c.angle = -22
    case .chart:
      c.color = "#8CE2C1"
      c.w = 0.78
      c.h = 0.72
      c.length = 150
    case .highlight:
      c.w = 0.35
      c.h = 0.12
      c.opacity = 0.62
    case .rectangle, .ellipse:
      c.color = "#85CEF3"
      c.h = 0.25
      c.shapeAppearance = ShapeAppearance(fill: .hollow)
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
  var captionTerms: String?
  var captionGlossary: String?
  var trackOrder: [String]?
  var backgroundColor: String?
  var background: String { backgroundColor ?? "#000000" }
  var version = 1
  var canvas = Canvas.wide
  var assets: [Media] = []
  var clips: [Clip] = []
  var duration: Int { clips.lazy.map(\.end).max() ?? 0 }
  func asset(_ id: UUID?) -> Media? { assets.first { $0.id == id } }
  var mediaByID: [UUID: Media] {
    Dictionary(assets.lazy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  func hasSameTimelineMedia(as previous: Project) -> Bool {
    guard assets != previous.assets else { return true }
    let used = Set(clips.compactMap { $0.kind.isMedia ? $0.asset : nil })
    return assets.filter { used.contains($0.id) } == previous.assets.filter { used.contains($0.id) }
  }
  func name(_ c: Clip) -> String {
    if c.kind.isMedia { return asset(c.asset)?.name ?? c.kind.title }
    if let visual = c.audioVisualization { return L("音频可视化 · \(visual.style.title)") }
    if let chart = c.chart { return chart.title.isEmpty ? chart.kind.title : chart.title }
    return c.text.isEmpty ? c.kind.title : c.text
  }
  func expandingGroups(_ ids: [UUID]) -> [UUID] {
    let selected = Set(ids)
    let groups = Set(clips.lazy.filter { selected.contains($0.id) }.compactMap(\.groupID))
    guard !groups.isEmpty else { return ids }
    let members = clips.filter { !selected.contains($0.id) && $0.groupID.map(groups.contains) == true }
    return members.map(\.id) + ids
  }
  mutating func group(_ ids: [UUID]) {
    let members = Set(expandingGroups(ids))
    guard clips.lazy.filter({ members.contains($0.id) }).prefix(2).count == 2 else { return }
    let groupID = UUID()
    for i in clips.indices where members.contains(clips[i].id) { clips[i].groupID = groupID }
  }
  mutating func ungroup(_ ids: [UUID]) {
    let members = Set(expandingGroups(ids))
    for i in clips.indices where members.contains(clips[i].id) { clips[i].groupID = nil }
  }
  mutating func clearSingletonGroups() {
    var seen = Set<UUID>(), shared = Set<UUID>()
    for id in clips.compactMap(\.groupID) where !seen.insert(id).inserted { shared.insert(id) }
    for i in clips.indices where clips[i].groupID.map(shared.contains) == false { clips[i].groupID = nil }
  }
  func checked() throws -> Project {
    let media = mediaByID
    guard version == 1, media.count == assets.count,
      Set(clips.map(\.id)).count == clips.count
    else { throw EditError.message(L("工程版本或素材编号无效。")) }
    if let style = captionStyle, !style.valid { throw EditError.message(L("字幕样式超出范围。")) }
    for a in assets {
      guard a.frames > 0, a.frames <= maxFrames, a.path.hasPrefix("/") else {
        throw EditError.message(L("工程素材记录无效。"))
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
        (0...64).contains(c.lensBorderWidth ?? Clip.defaultLensBorderWidth),
        (0...300).contains(c.entranceFrames), (1...300).contains(c.motionFrames),
        c.shakeAmplitude.map({ (0...0.1).contains($0) }) != false,
        c.shakeFrequency.map({ (0.1...12).contains($0) }) != false,
        c.motionZoom.map({ (1...3).contains($0) }) != false,
        c.motion == .path ? (c.supportsMotion && c.motionPath?.valid == true) : c.motionPath == nil,
        (0.05...8).contains(c.displayScale), (0...1).contains(c.filterAmount ?? 1),
        c.filters.allSatisfy(\.valid),
        c.sourceCrop?.valid != false, c.visualBorder?.valid != false,
        c.pictureInset?.valid != false, c.kind != .editorial || c.editorial?.valid == true,
        c.kind != .audioVisual || c.audioVisualization?.valid == true,
        c.textAppearance?.valid != false, c.textAnimation?.valid != false, c.timerSettings?.valid != false,
        c.shapeAppearance?.valid != false,
        (-maxFrames...2 * maxFrames).contains(c.timerPhase ?? 0),
        [c.startEffect, c.endEffect].compactMap { $0 }.allSatisfy { (2...90).contains($0.frames) },
        (0...90).contains(c.blend), (0...maxFrames).contains(c.fixedCutOffset ?? 0)
      else { throw EditError.message(L("片段的时间或属性超出范围。")) }
      if c.kind == .chart, c.chart?.valid != true || c.chartAppearance?.valid == false {
        throw EditError.message(L("工程图表数据无效。"))
      }
      if c.kind.isMedia {
        guard let a = c.asset.flatMap({ media[$0] }), (0.25...4).contains(c.rate), (-12...12).contains(c.pitch),
          (0..<1.0).contains(c.sourceFraction ?? 0), c.sourceLength > 0,
          a.isStill || c.sourceEnd <= Double(a.frames) + 1e-7,
          c.kind == .video ? a.video : a.audio
        else { throw EditError.message(L("素材与片段不匹配。")) }
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
    clearSingletonGroups()
  }
  static func read(from url: URL) throws -> Project {
    var p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    for i in p.assets.indices {
      if let sound = p.assets[i].soundID {
        guard let u = BuiltInSound(rawValue: sound)?.url else {
          throw EditError.message(L("找不到内置音效「\(sound)」。"))
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
  struct Join: Identifiable, Equatable {
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
  var joins: [Join] { videoJoins + artworkJoins }

  var artworkJoins: [Join] {
    guard clips.contains(where: { $0.kind.supportsArtworkTransitions }) else { return [] }
    return annotationLanes().flatMap { lane in
      zip(lane, lane.dropFirst()).compactMap { before, after in
        guard before.end == after.start, before.length >= 3, after.length >= 3,
          before.kind.supportsArtworkTransitions, after.kind.supportsArtworkTransitions
        else { return nil }
        return Join(before: before, after: after)
      }
    }
  }

  private var videoJoins: [Join] {
    let videos = clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
    let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
    let ending = Dictionary(grouping: videos, by: \.end)
    return videos.compactMap { next in
      let explicit = next.from.flatMap { byID[$0] }
      let left =
        explicit.flatMap { $0.start < next.start && $0.end > next.start ? $0 : nil }
        ?? ending[next.start]?.last(where: { ($0.pictureInset == nil) == (next.pictureInset == nil) })
      guard let left, left.length >= 3, next.length >= 3 else { return nil }
      return Join(before: left, after: next)
    }
  }
  // A connected chain occupies one editing lane over its combined time range.
  // Unrelated overlapping video remains independently selectable on another lane.
  func videoLanes(_ joins: [Join], insets: Bool = false) -> [[Clip]] {
    let clips = self.clips.filter { $0.kind == .video && ($0.pictureInset != nil) == insets }
      .sorted { $0.start < $1.start }
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
    return rows.isEmpty && !insets ? [[]] : rows
  }
  var videoVisibility: [UUID: Range<Int>] {
    var spans = Dictionary(
      uniqueKeysWithValues: clips.filter { $0.kind == .video }.map { ($0.id, $0.start..<$0.end) })
    extendVisibility(&spans, across: videoJoins)
    return spans
  }

  var artworkTransitionVisibility: [UUID: Range<Int>] {
    let active = artworkJoins.filter(\.active)
    var spans: [UUID: Range<Int>] = [:]
    for join in active {
      spans[join.before.id] = join.before.start..<join.before.end
      spans[join.after.id] = join.after.start..<join.after.end
    }
    extendVisibility(&spans, across: active)
    return spans
  }

  private func extendVisibility(_ spans: inout [UUID: Range<Int>], across joins: [Join]) {
    for j in joins where j.after.from == j.before.id && j.after.fixedCutOffset != nil {
      let cut = j.range
      guard let left = spans[j.before.id], let right = spans[j.after.id],
        left.lowerBound < cut.upperBound, cut.lowerBound < right.upperBound
      else { continue }
      spans[j.before.id] = left.lowerBound..<cut.upperBound
      spans[j.after.id] = cut.lowerBound..<right.upperBound
    }
  }
  func transitionEffect(_ target: TransitionTarget) -> ClipEdgeEffect? {
    switch target {
    case .join(let id):
      guard let join = joins.first(where: { $0.id == id && $0.active }) else { return nil }
      return ClipEdgeEffect(style: join.after.transitionStyle, frames: join.after.blend)
    case .edge(let edge):
      return clips.first(where: { $0.id == edge.clipID })?.effect(at: edge.end)
    }
  }
  func transitionFrameLimit(_ target: TransitionTarget) -> Int {
    switch target {
    case .join(let id):
      let links = joins
      guard let join = links.first(where: { $0.id == id }) else { return 0 }
      let previous = links.first { $0.id == join.before.id }?.frame ?? join.before.start
      let next = links.first { $0.before.id == id }?.frame ?? join.after.end
      return min(90, join.frame - previous, next - join.frame)
    case .edge(let edge):
      guard let c = clips.first(where: { $0.id == edge.clipID && $0.kind.supportsTransitions }),
        c.length >= 2
      else { return 0 }
      let other = c.effect(at: edge.end == .head ? .tail : .head)
      if other != nil && c.length < 4 { return 0 }
      return min(90, c.length - min(c.length - 2, other?.frames ?? 0))
    }
  }
  mutating func updateTransition(
    _ target: TransitionTarget, frames: Int, style: TransitionLook? = nil
  ) throws {
    switch target {
    case .join(let id): try setTransition(id, frames: frames, style: style)
    case .edge(let edge): try setEdgeEffect(edge, frames: frames, style: style)
    }
  }
  mutating func moveTransition(from origin: TransitionTarget, to destination: TransitionTarget) throws {
    guard origin != destination, let effect = transitionEffect(origin) else { return }
    var next = self
    try next.updateTransition(origin, frames: 0)
    try next.placeTransition(effect.style, on: [destination], preferredFrames: effect.frames)
    self = next
  }
  mutating func placeTransition(
    _ style: TransitionLook, on targets: [TransitionTarget], preferredFrames: Int? = nil
  ) throws {
    var next = self
    let selected = Set(targets)
    for case .edge(let edge) in targets where edge.end == .head {
      let tail = TransitionTarget.edge(EdgeTarget(clipID: edge.clipID, end: .tail))
      if selected.contains(tail) {
        try next.updateTransition(.edge(edge), frames: 0)
        try next.updateTransition(tail, frames: 0)
      }
    }
    for target in targets {
      let originalFrames = preferredFrames ?? transitionEffect(target)?.frames ?? 15
      var duration = originalFrames
      switch target {
      case .join(let id):
        if let join = next.joins.first(where: { $0.id == id }),
          join.before.end == join.frame, join.after.start == join.frame
        {
          try next.setEdgeEffect(EdgeTarget(clipID: join.before.id, end: .tail), frames: 0, style: nil)
          try next.setEdgeEffect(EdgeTarget(clipID: join.after.id, end: .head), frames: 0, style: nil)
        }
      case .edge(let edge):
        if let c = next.clips.first(where: { $0.id == edge.clipID }) {
          let opposite = TransitionTarget.edge(
            EdgeTarget(clipID: edge.clipID, end: edge.end == .head ? .tail : .head))
          if selected.contains(opposite) { duration = min(originalFrames, c.length / 2) }
          if let join = next.joins.first(where: {
            $0.active && ($0.before.end == $0.frame && $0.after.start == $0.frame)
              && (edge.end == .head ? $0.after.id == c.id : $0.before.id == c.id)
          }) {
            try next.setTransition(join.id, frames: 0)
          }
        }
      }
      try next.updateTransition(target, frames: duration, style: style)
    }
    self = next
  }
  mutating func setEdgeEffect(_ target: EdgeTarget, frames: Int, style: TransitionLook?) throws {
    guard let index = clips.firstIndex(where: { $0.id == target.clipID }),
      clips[index].kind.supportsTransitions
    else { throw EditError.message(L("请选择支持转场的片段首端或末端。")) }
    let c = clips[index]
    let available = transitionFrameLimit(.edge(target))
    if frames > 0 && available < 2 {
      throw EditError.message(L("片段太短，请先延长片段或移除另一端的转场。"))
    }
    let next =
      frames <= 0
      ? nil
      : ClipEdgeEffect(
        style: style ?? c.effect(at: target.end)?.style ?? .slide,
        frames: bound(frames, 2, available))
    if target.end == .head {
      clips[index].startEffect = next
    } else {
      clips[index].endEffect = next
    }
  }

  mutating func setTransition(_ id: UUID, frames: Int, style: TransitionLook? = nil) throws {
    guard let join = joins.first(where: { $0.id == id }),
      let i = clips.firstIndex(where: { $0.id == id })
    else { throw EditError.message(L("请先让两个支持转场的片段在同一轨道首尾相接。")) }
    let cut = join.frame
    let n = frames == 0 ? 0 : min(max(2, frames), transitionFrameLimit(.join(id)))
    guard frames == 0 || n >= 2 else { throw EditError.message(L("这两个片段没有足够长度添加转场。")) }
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
        throw EditError.message(L("第 \(result.count+1) 条字幕缺少时间码或正文。"))
      }
      let pair = lines[t].components(separatedBy: "-->")
      guard pair.count == 2, let start = frame(pair[0][...]), let end = frame(pair[1][...]),
        end > start, end <= maxFrames
      else { throw EditError.message(L("第 \(result.count+1) 条字幕时间码无效。")) }
      var c = Clip.annotation(.caption, at: start)
      c.length = end - start
      c.text = lines[(t + 1)...].joined(separator: "\n")
      result.append(c)
    }
    guard !result.isEmpty else { throw EditError.message(L("字幕文件为空。")) }
    return result
  }
  static func write(_ clips: [Clip]) -> String {
    func stamp(_ f: Int) -> String {
      let v = Int((Double(f) * 1000 / 30).rounded())
      return String(
        format: "%02d:%02d:%02d,%03d", v / 3_600_000, v / 60000 % 60, v / 1000 % 60, v % 1000)
    }
    return clips.filter { $0.kind == .caption }.sorted { $0.start < $1.start }.enumerated().map {
      i, c in "\(i+1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.captionText)\n"
    }.joined(separator: "\n")
  }
}
