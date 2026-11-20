import CoreGraphics
import Foundation

enum InsetShape: String, Codable, CaseIterable {
  case circle, rounded, rectangle

  var title: String {
    switch self {
    case .circle: return L("圆形")
    case .rounded: return L("圆角矩形")
    case .rectangle: return L("矩形")
    }
  }
  var aspect: CGFloat { self == .circle ? 1 : 4.0 / 3.0 }

  func path(_ rect: CGRect) -> CGPath {
    if self == .circle { return CGPath(ellipseIn: rect, transform: nil) }
    let radius = self == .rounded ? min(rect.width, rect.height) * 0.12 : 0
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }
}

enum InsetCorner: CaseIterable {
  case bottomLeft, bottomRight, topLeft, topRight

  var title: String {
    switch self {
    case .bottomLeft: return L("左下")
    case .bottomRight: return L("右下")
    case .topLeft: return L("左上")
    case .topRight: return L("右上")
    }
  }
  func center(canvas: CGSize, height: CGFloat, aspect: CGFloat) -> CGPoint {
    let margin = min(canvas.width, canvas.height) * 0.045
    let x = min(0.5, (margin + height * aspect / 2) / canvas.width)
    let y = min(0.5, (margin + height / 2) / canvas.height)
    return CGPoint(x: self == .topLeft || self == .bottomLeft ? x : 1 - x,
                   y: self == .topLeft || self == .topRight ? y : 1 - y)
  }
}

struct PictureInset: Codable, Equatable {
  var shape = InsetShape.circle
  var originalX: Double
  var originalY: Double
  var originalScale: Double?
  var originalAngle: Double
  var originalBorder: VisualBorder?

  init(_ clip: Clip) {
    originalX = clip.x
    originalY = clip.y
    originalScale = clip.visualScale
    originalAngle = clip.angle
    originalBorder = clip.visualBorder
  }

  var valid: Bool {
    (-4...5).contains(originalX) && (-4...5).contains(originalY)
      && (0.05...8).contains(originalScale ?? 1) && (-360...360).contains(originalAngle)
      && originalBorder?.valid != false
  }
}

extension Project {
  mutating func applyPictureInset(to id: UUID, over backdrop: UUID? = nil) -> UUID? {
    guard let host = clips.first(where: { $0.id == id && $0.kind == .video && $0.pictureInset == nil }) else {
      return nil
    }
    var target = host.id
    if let backdrop {
      guard backdrop != id, let other = clips.first(where: { $0.id == backdrop && $0.kind == .video }) else {
        return nil
      }
      let start = max(host.start, other.start)
      let end = min(host.end, other.end)
      guard start < end else { return nil }
      if start > host.start, let piece = cut(target, at: start) { target = piece }
      if end < host.end { _ = cut(target, at: end) }
    }
    guard let index = clips.firstIndex(where: { $0.id == target }) else { return nil }
    clips[index].addPictureInset(canvas: canvas.size(540))
    return target
  }
}

extension Clip {
  mutating func addPictureInset(canvas: CGSize) {
    guard kind == .video, pictureInset == nil else { return }
    pictureInset = PictureInset(self)
    visualScale = 0.23
    angle = 0
    visualBorder = VisualBorder(style: .solid, width: 5)
    placePictureInset(.bottomLeft, canvas: canvas)
  }

  mutating func placePictureInset(_ corner: InsetCorner, canvas: CGSize) {
    guard let inset = pictureInset else { return }
    let height = min(canvas.width, canvas.height) * displayScale
    let center = corner.center(canvas: canvas, height: height, aspect: inset.shape.aspect)
    x = center.x
    y = center.y
  }

  mutating func removePictureInset() {
    guard let inset = pictureInset else { return }
    x = inset.originalX
    y = inset.originalY
    visualScale = inset.originalScale
    angle = inset.originalAngle
    visualBorder = inset.originalBorder
    pictureInset = nil
  }

  mutating func applyDataStoryStyle() {
    guard let chart else { return }
    var style = chartAppearance ?? ChartAppearance()
    style.theme = .dark
    style.backgroundOpacity = 0.87
    style.showsGrid = true
    if chart.kind == .line {
      style.colorMode = .single
      style.areaFill = true
      color = "#B29BFF"
    } else if chart.kind == .bar {
      style.colorMode = .sign
      style.lowColor = "#F18CA7"
      color = "#85AEFF"
    }
    chartAppearance = style
  }
}

enum EditorialStyle: String, Codable, CaseIterable {
  case chapter, metric, cards

  var title: String {
    switch self {
    case .chapter: return L("章节标题")
    case .metric: return L("动态大数字")
    case .cards: return L("三卡并列")
    }
  }
  var icon: String {
    switch self {
    case .chapter: return "text.aligncenter"
    case .metric: return "number"
    case .cards: return "rectangle.split.3x1"
    }
  }

  func clip(at frame: Int) -> Clip {
    var clip = Clip(kind: .editorial, start: frame, length: min(maxFrames - frame, self == .chapter ? 90 : 120))
    clip.editorial = EditorialSpec(style: self)
    clip.text = self == .cards ? L("三项要点") : title
    clip.w = 1
    clip.h = 1
    clip.color = self == .chapter ? "#FFDEA0" : "#BDE8D1"
    return clip
  }
}

struct EditorialCard: Codable, Equatable {
  var title: String
  var detail = ""
  var icon: EditorialCardIcon?
  var background: String?
  var accent: String?
  var picture: Data?

  static let backgrounds = ["#20303B", "#242941", "#342638"]
  static let accents = ["#BDE8D1", "#ADA7FF", "#F4AEBB"]
  static let maximumPictureBytes = 768 * 1024
}

enum EditorialCardIcon: String, Codable, CaseIterable {
  case none, context, trend, target, idea, check, alert

  var title: String {
    switch self {
    case .none: return L("无")
    case .context: return L("背景")
    case .trend: return L("趋势")
    case .target: return L("目标")
    case .idea: return L("想法")
    case .check: return L("完成")
    case .alert: return L("提示")
    }
  }

  var symbol: String? {
    switch self {
    case .none: return nil
    case .context: return "square.stack"
    case .trend: return "chart.line.uptrend.xyaxis"
    case .target: return "target"
    case .idea: return "lightbulb"
    case .check: return "checkmark"
    case .alert: return "exclamationmark"
    }
  }
}

enum EditorialCardLayout: String, Codable, CaseIterable {
  case automatic, horizontal, vertical

  var title: String {
    switch self {
    case .automatic: return L("自动")
    case .horizontal: return L("横排")
    case .vertical: return L("纵排")
    }
  }
  func isHorizontal(in rect: CGRect) -> Bool {
    self == .horizontal || (self == .automatic && rect.width >= rect.height)
  }
}

struct EditorialCardsAppearance: Codable, Equatable {
  var layout = EditorialCardLayout.automatic
  var gap = 14.0
  var corner = 12.0
  var detailSize = 16.0
  var featured: Int?
  var stagger = 2.0 / 9
  var reverse = false

  var valid: Bool {
    (4...26).contains(gap) && (0...30).contains(corner) && (12...25).contains(detailSize)
      && (0...0.4).contains(stagger) && featured.map { (0..<3).contains($0) } != false
  }

  func reveal(for card: Int, at progress: Double) -> Double {
    let order = reverse ? 2 - card : card
    return bound((progress - Double(order) * stagger) / (1 - 2 * stagger), 0, 1)
  }
}

enum EditorialCounting: String, Codable, CaseIterable {
  case easeOut, linear, easeInOut

  var title: String {
    switch self {
    case .easeOut: return L("先快后慢")
    case .linear: return L("匀速")
    case .easeInOut: return L("慢快慢")
    }
  }

  func position(_ progress: Double) -> Double {
    let t = bound(progress, 0, 1)
    switch self {
    case .easeOut: return 1 - pow(1 - t, 3)
    case .linear: return t
    case .easeInOut: return t * t * (3 - 2 * t)
    }
  }
}

struct EditorialMetricAppearance: Codable, Equatable {
  var start = 0.0
  var counting = EditorialCounting.easeOut
  var groupsDigits = false
  var showsPlus = false
  var font = ""
  var size = 1.0
  var unitSize = 1.0

  var valid: Bool {
    (-1e12...1e12).contains(start) && (0.55...1.45).contains(size) && (0.35...1).contains(unitSize)
  }
}

struct EditorialSpec: Codable, Equatable {
  var style: EditorialStyle
  var subtitle = ""
  var value = 50.0
  var prefix = ""
  var suffix = "%"
  var decimals = 0
  var entryFrames = 23
  var exitFrames: Int?
  var scrim = 0.63
  var cardsAppearance: EditorialCardsAppearance?
  var metricAppearance: EditorialMetricAppearance?
  var metricReveal: MetricReveal?
  var activeMetricReveal: MetricReveal? {
    guard style == .metric, let metricReveal, metricReveal.enabled else { return nil }
    return metricReveal
  }
  var cards = [EditorialCard(title: L("背景")), EditorialCard(title: L("变化")),
               EditorialCard(title: L("影响"))]

  var valid: Bool {
    (-1e12...1e12).contains(value) && (0...3).contains(decimals) && (0...maxFrames).contains(entryFrames)
      && (0...1).contains(scrim) && cards.count == 3
      && (0...maxFrames).contains(exitFrames ?? 0)
      && cardsAppearance?.valid != false && metricAppearance?.valid != false && metricReveal?.valid != false
      && cards.allSatisfy { ($0.picture?.count ?? 0) <= EditorialCard.maximumPictureBytes }
  }

  func progress(frame: Int, clip: Clip) -> Double {
    if let reveal = activeMetricReveal { return reveal.progress(at: frame - clip.start) }
    let span = ramps(clip).entry
    return span == 0 ? 1 : bound(Double(frame - clip.start) / Double(span), 0, 1)
  }

  func exitOpacity(frame: Int, clip: Clip) -> Double {
    let span = activeMetricReveal?.exitSpan(requested: exitFrames ?? 0, lastFrame: clip.length - 1) ?? ramps(clip).exit
    guard span > 0 else { return 1 }
    let t = bound(Double(clip.end - 1 - frame) / Double(span), 0, 1)
    return t * t * (3 - 2 * t)
  }

  private func ramps(_ clip: Clip) -> (entry: Int, exit: Int) {
    let frames = clip.length - 1
    let exit = exitFrames ?? 0
    if frames == 0 { return (0, 0) }
    if entryFrames + exit <= frames { return (entryFrames, exit) }
    if entryFrames == 0 { return (0, frames) }
    if exit == 0 || frames == 1 { return (frames, 0) }
    let entry = bound(Int((Double(frames * entryFrames) / Double(entryFrames + exit)).rounded()), 1, frames - 1)
    return (entry, frames - entry)
  }

  mutating func useMetricReveal(_ enabled: Bool, clipLength: Int) {
    if enabled && metricReveal == nil { metricReveal = MetricReveal(clipLength: clipLength) }
    metricReveal?.enabled = enabled
  }

  mutating func shiftReveal(by frames: Int) {
    if let offset = metricReveal?.offsetFrames {
      metricReveal?.offsetFrames = bound(offset + frames, -maxFrames, maxFrames)
    }
  }

  var metricStart: Double {
    activeMetricReveal?.mode == .share ? 0 : (metricAppearance?.start ?? 0)
  }

  func metricValue(_ progress: Double) -> Double {
    if progress <= 0 { return metricStart }
    if progress >= 1 { return value }
    let counting = metricAppearance?.counting ?? .easeOut
    return metricStart + (value - metricStart) * counting.position(progress)
  }

  func number(_ progress: Double) -> String {
    prefix + digits(progress) + suffix
  }

  func digits(_ progress: Double) -> String { formatMetric(metricValue(progress)) }

  func formatMetric(_ number: Double, plus: Bool = true) -> String {
    let style = metricAppearance ?? EditorialMetricAppearance()
    let step = pow(10, Double(decimals))
    let rounded = (number * step).rounded() / step
    let sign = rounded < 0 ? "-" : (plus && style.showsPlus && rounded > 0 ? "+" : "")
    let raw = String(format: "%.*f", decimals, abs(rounded))
    guard style.groupsDigits else { return sign + raw }
    let parts = raw.split(separator: ".", maxSplits: 1)
    let digits = parts[0]
    let grouped = digits.enumerated().reduce(into: "") { string, element in
      let (index, digit) = element
      if index > 0 && (digits.count - index).isMultiple(of: 3) { string.append(",") }
      string.append(digit)
    }
    return sign + grouped + (parts.count == 2 ? "." + parts[1] : "")
  }
}
