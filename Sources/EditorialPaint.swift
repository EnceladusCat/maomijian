import AppKit
import CoreText

enum EditorialPaint {
  static func draw(_ spec: EditorialSpec, title: String, accent: String, in rect: CGRect,
                   progress: Double, context g: CGContext) {
    let reveal = spec.activeMetricReveal
    let fade = reveal == nil ? min(1, progress * 2.1) : 1
    guard fade > 0 else { return }
    g.setFillColor(ink("#11141F", spec.scrim * fade))
    g.fill(rect)
    if spec.style == .cards {
      EditorialCardsPaint.draw(spec, title: title, accent: accent, in: rect, progress: progress, context: g)
      return
    }

    let wide = rect.width >= rect.height
    let design = CGSize(width: wide ? 720 : 430, height: wide ? 360 : 610)
    let scale = min(rect.width / design.width, rect.height / design.height)
    g.saveGState()
    g.translateBy(x: rect.midX - design.width * scale / 2, y: rect.midY - design.height * scale / 2)
    g.scaleBy(x: scale, y: scale)
    let x = design.width / 2
    let y = design.height / 2
    let contentWidth = design.width * 0.87
    let tint = ink(accent, fade)
    if let reveal {
      paintReveal(spec, reveal: reveal, title: title, accent: tint, size: design,
                  wide: wide, progress: progress, context: g)
      g.restoreGState()
      return
    }
    switch spec.style {
    case .chapter:
      let offset = -12 * (1 - progress) * (1 - progress)
      let hasSubtitle = !spec.subtitle.isEmpty
      let titleY = y + (hasSubtitle ? 7 : -19) + offset
      label(title, at: CGPoint(x: x, y: titleY), width: contentWidth, size: wide ? 46 : 39,
            color: ink("#F4F7FD", fade), weight: .heavy, context: g)
      g.setFillColor(tint)
      let mark = CGRect(x: x - progress * 23, y: titleY - 13, width: progress * 46, height: 3)
      g.fill(mark)
      label(spec.subtitle, at: CGPoint(x: x, y: y - 39 + offset), width: contentWidth, size: 17,
            color: ink("#B8C5DA", fade), context: g)
    case .metric:
      let hasCaption = !title.isEmpty && !spec.subtitle.isEmpty
      let baseline = y - 25 + (hasCaption ? 0 : 9)
      let height = y + 82 - baseline
      let number = metricLine(spec, progress: progress, size: wide ? 95 : 77,
                              width: contentWidth, height: height, color: tint)
      let lineWidth = CTLineGetTypographicBounds(number, nil, nil, nil)
      let top = CTLineGetBoundsWithOptions(number, .useGlyphPathBounds).maxY + baseline
      label(title, at: CGPoint(x: x, y: max(top + 16, y + 65)), width: contentWidth,
            size: 19, color: ink("#CAD5E7", fade), weight: .semibold, context: g)
      g.textMatrix = .identity
      g.textPosition = CGPoint(x: x - lineWidth / 2, y: baseline)
      CTLineDraw(number, g)
      label(spec.subtitle, at: CGPoint(x: x, y: baseline - 33), width: contentWidth, size: 16,
            color: ink("#B8C5DA", fade), context: g)
    case .cards:
      break
    }
    g.restoreGState()
  }

  private static func paintReveal(_ spec: EditorialSpec, reveal: MetricReveal, title: String,
                                  accent: CGColor, size: CGSize, wide: Bool, progress: Double,
                                  context g: CGContext) {
    let comparing = reveal.mode == .comparison
    let start = spec.metricStart
    let bar = reveal.bar(from: start, to: spec.value, showing: spec.metricValue(progress))
    let width = size.width * (wide ? 0.72 : 0.82)
    let left = (size.width - width) / 2
    let middle = size.height / 2
    let baseline = middle - 12
    label(title, at: CGPoint(x: left, y: baseline + 104), width: width, size: wide ? 20 : 19,
          color: ink("#E1E7F2"), weight: .semibold, alignment: 0, context: g)

    if comparing || progress > 0 {
      let number = metricLine(spec, progress: progress, size: wide ? 96 : 79, width: width,
                              height: 91, color: progress > 0 ? accent : ink("#BEC9DA"))
      g.textMatrix = .identity
      g.textPosition = CGPoint(x: left, y: baseline)
      CTLineDraw(number, g)
    }

    let track = CGRect(x: left, y: baseline - 25, width: width, height: 8)
    let shape = CGPath(roundedRect: track, cornerWidth: 4, cornerHeight: 4, transform: nil)
    g.saveGState()
    g.addPath(shape)
    g.clip()
    g.setFillColor(ink("#354151"))
    g.fill(track)
    func fill(_ from: Double, _ to: Double, _ color: CGColor) {
      guard from != to else { return }
      g.setFillColor(color)
      g.fill(CGRect(x: left + min(from, to) * width, y: track.minY,
                    width: abs(to - from) * width, height: track.height))
    }
    if comparing { fill(bar.zero, bar.baseline, ink("#687789")) }
    fill(bar.accent.lowerBound, bar.accent.upperBound, accent)
    g.restoreGState()

    if bar.lower < 0 || comparing {
      let mark = comparing ? bar.baseline : bar.zero
      let x = left + mark * width
      g.setFillColor(ink("#8795A8"))
      g.fill(CGRect(x: x - 0.5, y: track.maxY + 3, width: 1, height: 4))
    }

    let scaleY = track.minY - 16
    let labelColor = ink("#B9C5D5")
    let ends = [bar.lower, bar.upper]
    for (i, value) in ends.enumerated() {
      label(spec.formatMetric(value, plus: false) + spec.suffix,
            at: CGPoint(x: left + Double(i) * width, y: scaleY), width: width * 0.45,
            size: 12, color: labelColor, alignment: Double(i), context: g)
    }

    let contextY = scaleY - 30
    let captionWidth = comparing ? width * 0.5 : width
    label(spec.subtitle, at: CGPoint(x: left, y: contextY), width: captionWidth, size: 15,
          color: labelColor, alignment: 0, context: g)
    if comparing {
      let original = spec.prefix + spec.formatMetric(start) + spec.suffix
      label(L("对比值 \(original)"), at: CGPoint(x: left + width, y: contextY),
            width: spec.subtitle.isEmpty ? width : width * 0.46, size: 15,
            color: labelColor, alignment: 1, context: g)
    }
  }

  private static func metricLine(_ spec: EditorialSpec, progress: Double, size: CGFloat,
                                 width: CGFloat, height: CGFloat, color: CGColor) -> CTLine {
    let style = spec.metricAppearance ?? EditorialMetricAppearance()
    let tint = NSColor(cgColor: color) ?? .white
    let pointSize = size * style.size
    let digits = spec.digits(progress)
    func line(_ value: String, size: CGFloat) -> CTLine {
      let numberFont = style.font.isEmpty ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy)
        : textFont(style.font, bold: true, size: size)
      let unitFont = style.unitSize == 1 ? numberFont
        : textFont(style.font, bold: true, size: size * style.unitSize)
      let result = NSMutableAttributedString()
      for (text, font) in [(spec.prefix, unitFont), (value, numberFont), (spec.suffix, unitFont)] where !text.isEmpty {
        result.append(NSAttributedString(string: text.components(separatedBy: .newlines).joined(separator: " "),
                                         attributes: [.font: font, .foregroundColor: tint]))
      }
      return CTLineCreateWithAttributedString(result)
    }
    let current = line(digits, size: pointSize)
    var ascent: CGFloat = 0
    let currentWidth = CTLineGetTypographicBounds(current, &ascent, nil, nil)
    let endpoints = [spec.digits(0), spec.digits(1)]
    let longestWidth = endpoints.reduce(currentWidth) { longest, endpoint in
      max(longest, CTLineGetTypographicBounds(line(endpoint, size: pointSize), nil, nil, nil))
    }
    let scale = min(1, width / max(1, longestWidth), height / max(1, ascent))
    return scale < 1 ? line(digits, size: pointSize * scale) : current
  }

  private static func label(_ text: String, at origin: CGPoint, width: CGFloat, size: CGFloat, color: CGColor,
                            weight: NSFont.Weight = .medium, alignment: Double = 0.5, context g: CGContext) {
    guard !text.isEmpty else { return }
    let text = text.components(separatedBy: .newlines).joined(separator: " ")
    func line(_ size: CGFloat) -> CTLine {
      let font = NSFont.systemFont(ofSize: size, weight: weight)
      return CTLineCreateWithAttributedString(NSAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white]))
    }
    var shaped = line(size)
    var measured = CTLineGetTypographicBounds(shaped, nil, nil, nil)
    if measured > width {
      shaped = line(size * width / measured)
      measured = CTLineGetTypographicBounds(shaped, nil, nil, nil)
    }
    g.textMatrix = .identity
    g.textPosition = CGPoint(x: origin.x - measured * alignment, y: origin.y)
    CTLineDraw(shaped, g)
  }
}
