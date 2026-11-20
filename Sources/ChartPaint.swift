import AppKit
import CoreText

struct ChartLayout {
  let id = NSUUID()
  private let size: CGSize
  private let backdrop: CGImage?
  private let marks: [(path: CGPath, color: CGColor)]
  private let kind: ChartKind
  private let plot: CGRect
  private let baseline: CGFloat
  private let center: CGPoint
  private let radius: CGFloat
  private let slices: [(end: CGFloat, color: CGColor)]
  private let pieHole: CGFloat
  private let pieSeparator: CGColor
  private let strokeWidth: CGFloat
  private let typography: ChartTypography
  private let valueLabels: [(String, CGPoint)]
  private let area: CGPath?
  private let areaGradient: CGGradient?
  private let marker: (point: CGPoint, title: String, color: CGColor)?

  init(_ spec: ChartSpec, color: String, aspect: Double, appearance: ChartAppearance? = nil) {
    let style = appearance ?? ChartAppearance()
    let palette = ChartPalette(spec.points, mode: style.paletteMode(spec.kind), high: color, low: style.lowColor)
    let typography = ChartTypography(style)
    self.typography = typography
    let showValues = style.displaysValues(spec.kind)
    let hasLegend = style.showsLabels || showValues
    let paper = style.theme == .light
    let grid = ink(paper ? "#D9E2EC" : "#304055")
    pieSeparator = ink(paper ? "#F8FAFD" : "#141C2A", 0.92)
    strokeWidth = 3 * style.markSize
    let width = bound(340 * aspect, 380, 940).rounded()
    size = CGSize(width: width, height: 340)
    kind = spec.kind
    let left = style.showsLabels ? 75.0 : 28.0
    let bottom = style.showsLabels ? 62.0 : 29.0
    let plot = CGRect(x: left, y: bottom, width: width - left - 28,
                      height: (style.showsTitle ? 271 : 303) - bottom)
    self.plot = plot
    let center = CGPoint(x: width * (hasLegend ? 0.27 : 0.5), y: style.showsTitle ? 163 : 170)
    self.center = center
    let radius = hasLegend ? min(width * 0.218, 108) : 125
    self.radius = radius
    let hole = radius * style.pieHole
    self.pieHole = hole
    let rect = CGRect(origin: .zero, size: size)
    let g = bitmap(Int(width * 2), Int(size.height * 2))
    if let g {
      g.scaleBy(x: 2, y: 2)
      if style.theme != .transparent && style.backgroundOpacity > 0 {
        let frame = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 18, cornerHeight: 18,
                           transform: nil)
        g.setFillColor(ink(paper ? "#F8FAFD" : "#141C2A", style.backgroundOpacity))
        g.addPath(frame)
        g.fillPath()
        g.setStrokeColor(ink(paper ? "#D0D9E5" : "#34445B", style.backgroundOpacity))
        g.setLineWidth(1.5)
        g.addPath(frame)
        g.strokePath()
      }
      if style.showsTitle {
        typography.draw(spec.title.isEmpty ? spec.kind.title : spec.title,
                        at: CGPoint(x: 24, y: 300), width: width - 48, size: 26, bold: true, in: g)
        g.setFillColor(ink(color))
        g.fill(CGRect(x: 24, y: 287, width: 26, height: 3))
      }
    }

    let points = spec.points
    var paths = [Int: CGMutablePath]()
    var values = [(String, CGPoint)]()
    var filledArea: CGPath?
    var pointMarker: (CGPoint, String, CGColor)?
    if spec.kind == .pie {
      let maxValue = points.map(\.y).max() ?? 1
      let total = points.reduce(0) { $0 + $1.y / maxValue }
      var end = 0.0
      slices = points.enumerated().map { i, point in
        end += point.y / maxValue / total
        return (i == points.count - 1 ? 1 : min(1, end), palette.colors[palette.slots[i]])
      }
      baseline = 0
      if let g {
        g.setFillColor(ink(paper ? "#DCE6F0" : "#253448", 0.8))
        g.addEllipse(in: Self.diameter(center, radius))
        if hole > 0 { g.addEllipse(in: Self.diameter(center, hole)) }
        g.fillPath(using: .evenOdd)
      }
      if let g, hasLegend {
        let legendX = max(center.x + radius + 23, width * 0.54)
        let legendWidth = width - legendX - 24
        let more = points.count > 8
        let labelCount = min(points.count, more ? 7 : 8)
        let top = 163 + Double(labelCount - 1) * 13
        for i in 0..<labelCount {
          let y = top - Double(i) * 26
          g.setFillColor(slices[i].color)
          g.fillEllipse(in: CGRect(x: legendX, y: y, width: 10, height: 10))
          let share = Self.number(100 * (points[i].y / maxValue / total)) + "%"
          if style.showsLabels {
            typography.draw(points[i].label, at: CGPoint(x: legendX + 16, y: y - 1),
                            width: legendWidth - (showValues ? 73 : 16), size: 14, in: g)
          }
          if showValues {
            let x = style.showsLabels ? width - 24 : legendX + 16
            typography.draw(share, at: CGPoint(x: x, y: y - 1), width: 64,
                            size: 14, align: style.showsLabels ? 1 : 0, bold: true, in: g)
          }
        }
        if more {
          let extra = points.count - labelCount
          typography.draw(L("另有 \(extra) 项"), at: CGPoint(x: legendX, y: top - Double(labelCount) * 26),
                          width: legendWidth, size: 13, in: g)
        }
      }
    } else {
      slices = []
      let yDomain = ChartDomain(points.map(\.y), includeZero: spec.kind == .bar)
      let xDomain = ChartDomain(points.compactMap(\.x))
      baseline = plot.minY + yDomain.fraction(0) * plot.height
      let step = plot.width / Double(max(1, points.count))
      func xAt(_ i: Int, _ pt: ChartPoint) -> CGFloat {
        if spec.kind == .scatter { return plot.minX + xDomain.fraction(pt.x ?? 0) * plot.width }
        if spec.kind == .bar { return plot.minX + (Double(i) + 0.5) * step }
        return points.count == 1 ? plot.midX : plot.minX + Double(i) * plot.width / Double(points.count - 1)
      }
      if let g {
        g.setLineWidth(1)
        g.setStrokeColor(grid)
        for i in 0...4 {
          let fraction = Double(i) / 4
          let y = plot.minY + fraction * plot.height
          if style.showsGrid { g.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)]) }
          if style.showsLabels {
            typography.draw(Self.number(yDomain.value(fraction)), at: CGPoint(x: plot.minX - 10, y: y - 4),
                            width: 61, size: 13, align: 1, in: g)
          }
          if spec.kind == .scatter {
            let x = plot.minX + fraction * plot.width
            if style.showsGrid { g.strokeLineSegments(between: [CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)]) }
            if style.showsLabels {
              typography.draw(Self.number(xDomain.value(fraction)), at: CGPoint(x: x, y: 39),
                              width: plot.width / 5, size: 13, align: 0.5, in: g)
            }
          }
        }
        if spec.kind == .bar && style.showsGrid {
          g.setStrokeColor(ink(paper ? "#9BAEC3" : "#566880"))
          g.strokeLineSegments(between: [CGPoint(x: plot.minX, y: baseline), CGPoint(x: plot.maxX, y: baseline)])
        }
        if style.showsLabels && spec.kind != .scatter && !points.isEmpty {
          let ticks = min(points.count, max(2, Int(plot.width / (76 * style.fontScale))))
          for tick in 0..<ticks {
            let index = ticks == 1 ? 0 : Int((Double(tick) * Double(points.count - 1) / Double(ticks - 1)).rounded())
            let x = xAt(index, points[index])
            typography.draw(points[index].label, at: CGPoint(x: x, y: 39),
                            width: min(113, Double(plot.width) / Double(ticks) - 4),
                            size: 13, align: 0.5, in: g)
          }
        }
        if style.showsLabels {
          typography.draw(spec.xTitle, at: CGPoint(x: plot.midX, y: 15), width: plot.width, size: 13,
                          align: 0.5, bold: true, in: g)
          typography.draw(spec.yTitle, at: CGPoint(x: width - 25, y: plot.maxY + 6), width: plot.width - 70,
                          size: 13, align: 1, bold: true, in: g)
        }
      }
      var prior = CGPoint.zero
      var labelPositions = Set<Int>()
      let areaPath = spec.kind == .line && style.areaFill == true && points.count > 1 ? CGMutablePath() : nil
      for (i, point) in points.enumerated() {
        let x = xAt(i, point)
        let y = plot.minY + yDomain.fraction(point.y) * plot.height
        let position = CGPoint(x: x, y: y)
        let slot = palette.slots[i]
        if let areaPath {
          if i == 0 { areaPath.move(to: CGPoint(x: x, y: plot.minY)) }
          areaPath.addLine(to: position)
          if i == points.count - 1 {
            areaPath.addLine(to: CGPoint(x: x, y: plot.minY))
            areaPath.closeSubpath()
          }
        }
        if let selected = spec.marker, selected.row == i {
          pointMarker = (position, selected.title.isEmpty ? point.label : selected.title, palette.colors[slot])
        }
        let path = paths[slot] ?? CGMutablePath()
        paths[slot] = path
        switch spec.kind {
        case .bar:
          let width = min(52 * style.markSize, step * bound(0.7 * style.markSize, 0.23, 0.95))
          let bar = CGRect(x: x - width / 2, y: min(y, baseline), width: width, height: abs(y - baseline))
          path.addRect(bar)
        case .line where points.count > 1:
          if palette.colors.count == 1 {
            if i == 0 { path.move(to: position) }
            else { path.addLine(to: position) }
          } else if i > 0 {
            path.move(to: prior)
            path.addLine(to: position)
          }
          prior = position
        case .line, .scatter:
          let r = (points.count > 600 ? 2.0 : 4.5) * style.markSize
          path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        case .pie: break
        }
        if showValues {
          let labelY = y + (y > plot.maxY - 16 ? -18 : 8) * style.fontScale
          let cell = Int(x / (65 * style.fontScale)) + 128 * Int(labelY / (20 * style.fontScale))
          if labelPositions.insert(cell).inserted {
            values.append((Self.number(point.y), CGPoint(x: x, y: labelY)))
          }
        }
      }
      filledArea = areaPath
    }
    marks = paths.keys.sorted().compactMap { index in paths[index].map { ($0, palette.colors[index]) } }
    valueLabels = values
    area = filledArea
    areaGradient = filledArea == nil ? nil : CGGradient(
      colorsSpace: rgb, colors: [ink(color, 0.5), ink(color, 0.035)] as CFArray, locations: nil)
    marker = pointMarker
    backdrop = g?.makeImage()
    lineHasSegments = spec.kind == .line && points.count > 1
  }

  private let lineHasSegments: Bool

  func snapshot() -> CGImage? {
    guard let g = bitmap(Int(size.width * 2), Int(size.height * 2)) else { return nil }
    draw(in: CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2), progress: 1, context: g)
    return g.makeImage()
  }

  func fitted(to frame: CGRect) -> CGRect {
    let scale = min(frame.width / size.width, frame.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
  }

  private static func diameter(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
  }

  func draw(in frame: CGRect, progress: Double, context g: CGContext) {
    let fitted = fitted(to: frame)
    let scale = fitted.height / size.height
    g.saveGState()
    g.translateBy(x: fitted.minX, y: fitted.minY)
    g.scaleBy(x: scale, y: scale)
    if let backdrop { g.draw(backdrop, in: CGRect(origin: .zero, size: size)) }
    if kind == .pie {
      if pieHole > 0 {
        g.addRect(CGRect(origin: .zero, size: size))
        g.addEllipse(in: Self.diameter(center, pieHole))
        g.clip(using: .evenOdd)
      }
      g.setLineWidth(1.5)
      g.setStrokeColor(pieSeparator)
      var start = 0.0
      for slice in slices {
        if start >= progress { break }
        let end = min(progress, slice.end)
        let from = Double.pi / 2 - start * 2 * .pi
        let to = Double.pi / 2 - end * 2 * .pi
        if end > start {
          g.setFillColor(slice.color)
          g.beginPath()
          g.move(to: center)
          g.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: true)
          g.closePath()
          g.fillPath()
          if start > 0 {
            let outer = CGPoint(x: center.x + cos(CGFloat(from)) * radius, y: center.y + sin(CGFloat(from)) * radius)
            g.strokeLineSegments(between: [center, outer])
          }
        }
        start = end
      }
      if progress >= 1 && slices.count > 1 {
        g.strokeLineSegments(between: [center, CGPoint(x: center.x, y: center.y + radius)])
      }
    } else if progress > 0 {
      g.saveGState()
      if kind == .bar {
        g.translateBy(x: 0, y: baseline * (1 - progress))
        g.scaleBy(x: 1, y: progress)
      } else if progress < 1 {
        g.clip(to: CGRect(x: plot.minX - 6, y: plot.minY - 6,
                         width: (plot.width + 12) * progress, height: plot.height + 12))
      }
      if let area, let areaGradient {
        g.saveGState()
        g.addPath(area)
        g.clip()
        g.drawLinearGradient(areaGradient, start: CGPoint(x: plot.midX, y: plot.maxY),
                             end: CGPoint(x: plot.midX, y: plot.minY), options: [])
        g.restoreGState()
      }
      if lineHasSegments {
        g.setLineWidth(strokeWidth)
        g.setLineCap(.round)
        g.setLineJoin(.round)
      }
      for mark in marks {
        g.addPath(mark.path)
        if lineHasSegments {
          g.setStrokeColor(mark.color)
          g.strokePath()
        } else {
          g.setFillColor(mark.color)
          g.fillPath()
        }
      }
      g.restoreGState()
      if progress >= 1 {
        for (text, p) in valueLabels {
          typography.draw(text, at: p, width: 66, size: 12, align: 0.5, bold: true, in: g)
        }
      }
      if let marker,
        progress >= 1 || (kind != .bar && marker.point.x <= plot.minX + plot.width * progress)
      {
        let x = marker.point.x
        g.saveGState()
        g.setStrokeColor(marker.color)
        g.setLineWidth(1.25)
        g.setLineDash(phase: 0, lengths: [3, 4])
        g.strokeLineSegments(between: [CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)])
        g.setFillColor(marker.color)
        g.fillEllipse(in: Self.diameter(marker.point, 5))
        g.setFillColor(ink("#F4F7FD"))
        g.fillEllipse(in: Self.diameter(marker.point, 2))
        if !marker.title.isEmpty {
          let bubbleX = bound(x - 66, plot.minX, plot.maxX - 132)
          let bubbleY = marker.point.y > plot.maxY - 38 ? marker.point.y - 32 : marker.point.y + 15
          let bubble = CGRect(x: bubbleX, y: bubbleY, width: 132, height: 22)
          g.setFillColor(ink("#263249"))
          g.addPath(CGPath(roundedRect: bubble, cornerWidth: 5, cornerHeight: 5, transform: nil))
          g.fillPath()
          typography.draw(marker.title, at: CGPoint(x: bubble.midX, y: bubble.minY + 6),
                          width: 116, size: 12, align: 0.5, bold: true, overrideColor: "#F4F7FD", in: g)
        }
        g.restoreGState()
      }
    }
    g.restoreGState()
  }

  private static func number(_ number: Double) -> String {
    if abs(number) >= 10_000 || (number != 0 && abs(number) < 0.01) {
      return String(format: "%.2g", number)
    }
    return String(format: "%.4g", number)
  }
}

private struct ChartTypography {
  let style: ChartAppearance
  init(_ style: ChartAppearance) { self.style = style }

  func draw(_ text: String, at p: CGPoint, width: Double, size: Double, align: Double = 0,
            bold: Bool = false, overrideColor: String? = nil, in g: CGContext) {
    guard !text.isEmpty, width > 5 else { return }
    let color = overrideColor ?? style.textColor ?? (style.theme == .light
      ? (bold ? "#182438" : "#455570") : (bold ? "#F1F5FF" : "#B5C3DA"))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: textFont(style.font, bold: bold, size: size * style.fontScale),
      .foregroundColor: NSColor(cgColor: ink(color)) ?? .white,
    ]
    let text = text.components(separatedBy: .newlines).joined(separator: " ")
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
    let fitted = CTLineCreateTruncatedLine(line, width, .end, token) ?? line
    let measured = CTLineGetTypographicBounds(fitted, nil, nil, nil)
    guard measured <= width + 1 else { return }
    g.textMatrix = .identity
    g.textPosition = CGPoint(x: p.x - measured * align, y: p.y)
    CTLineDraw(fitted, g)
  }

}

private struct ChartDomain {
  let scale: Double
  let low: Double
  let high: Double

  init(_ data: [Double], includeZero: Bool = false) {
    let minValue = data.min() ?? 0
    let maxValue = data.max() ?? 1
    let maximum = max(abs(minValue), abs(maxValue))
    let scale = maximum == 0 ? 1 : maximum
    self.scale = scale
    let minScaled = (includeZero ? min(0, minValue) : minValue) / scale
    let maxScaled = (includeZero ? max(0, maxValue) : maxValue) / scale
    if maxScaled - minScaled < 1e-10 {
      low = minScaled - (minScaled > -0.8 ? 0.2 : 0)
      high = maxScaled + (maxScaled < 0.8 ? 0.2 : 0)
    } else {
      low = minScaled
      high = maxScaled
    }
  }

  func fraction(_ value: Double) -> Double { bound((value / scale - low) / (high - low), 0, 1) }
  func value(_ fraction: Double) -> Double {
    let value = (low + (high - low) * fraction) * scale
    return abs(value) < scale * 1e-12 ? 0 : value
  }
}
