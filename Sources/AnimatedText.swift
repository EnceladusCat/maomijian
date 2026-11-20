import CoreGraphics
import CoreText
import Foundation

/// Shapes the complete text once so revealing characters never reflows the other lines.
struct AnimatedTextLayout {
  private struct Run {
    let run: CTRun
    let baseline: CGPoint
    let utf16Indices: [Int]
    let outlines: [CGPath?]

    init(_ run: CTRun, baseline: CGPoint, start: Int, makeOutlines: Bool) {
      self.run = run
      self.baseline = baseline
      let count = CTRunGetGlyphCount(run)
      let range = CFRange(location: 0, length: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetStringIndices(run, range, &indices)
      utf16Indices = indices.map { $0 + start }
      if makeOutlines,
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]
      {
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, range, &glyphs)
        CTRunGetPositions(run, range, &positions)
        outlines = zip(glyphs, positions).map { glyph, point in
          var transform = CGAffineTransform(
            translationX: baseline.x + point.x, y: baseline.y + point.y)
          return CTFontCreatePathForGlyph(font as! CTFont, glyph, &transform)
        }
      } else {
        outlines = []
      }
    }

    func draw(before limit: Int, in g: CGContext) {
      var start: Int?
      for i in 0...utf16Indices.count {
        if i < utf16Indices.count, utf16Indices[i] < limit {
          if start == nil { start = i }
        } else if let first = start {
          g.textPosition = baseline
          CTRunDraw(run, g, CFRange(location: first, length: i - first))
          start = nil
        }
      }
    }
  }

  private let unit: CGFloat
  private let scale: CGFloat
  private let color: CGColor
  private let runs: [Run]
  private let underlines: [CGRect]
  private let underlineWidth: CGFloat
  private let graphemeEnds: [Int]
  private let fullFace: CGPath?
  private let shadow: TextShadow?

  init(_ clip: Clip, canvas: CGSize) {
    let unit = min(canvas.width, canvas.height) / 1080
    self.unit = unit
    let color = ink(clip.color)
    self.color = color
    let appearance = clip.textAppearance
    let characters = clip.textAnimation?.characters == true
    let rows: [(CTLine, CGPoint, Int)]
    if let appearance, appearance.usesFixedSize {
      scale = min(appearance.size / fixedTextPointSize * unit, 65536)
      let lines = fixedTextLines(clip.text, appearance: appearance, color: color, animateCharacters: characters)
      var start = 0
      rows = zip(lines, clip.text.components(separatedBy: "\n")).map { pair, text in
        defer { start += text.utf16.count + 1 }
        return (pair.0, pair.1, start)
      }
      shadow = appearance.shadow ?? TextShadow()
    } else {
      scale = 1
      let width = max(2, (clip.w * canvas.width).rounded())
      let height = max(2, (clip.h * canvas.height).rounded())
      let layout = WrappedText(clip, in: CGRect(x: 0, y: 0, width: width, height: height), unit: unit)
      rows = layout.lines.map { line, baseline in
        (line, CGPoint(x: baseline.x - width / 2, y: baseline.y - height / 2), 0)
      }
      shadow = appearance?.shadow ?? (clip.relief == nil
        ? TextShadow(blur: max(1, layout.fontSize * 0.08) / unit, y: 1 / unit) : nil)
    }
    let makeOutlines = clip.relief != nil || appearance?.activeDuotone != nil
      || (appearance?.outline.style ?? .none) != .none
    let runs = rows.flatMap { line, baseline, start in
      (CTLineGetGlyphRuns(line) as! [CTRun]).map {
        Run($0, baseline: baseline, start: start, makeOutlines: makeOutlines)
      }
    }
    self.runs = runs
    let fontUnit = unit / scale
    let underlines = rows.compactMap { line, baseline, _ -> CGRect? in
      var ascent: CGFloat = 0, descent: CGFloat = 0
      let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        - CTLineGetTrailingWhitespaceWidth(line)
      guard width > 0 else { return nil }
      let height = max(3 * fontUnit, (ascent + descent) * 0.09)
      return CGRect(x: baseline.x, y: baseline.y - descent - height - 2 * fontUnit,
                    width: width, height: height)
    }
    self.underlines = underlines
    underlineWidth = underlines.reduce(0) { $0 + $1.width }
    var index = 0
    graphemeEnds = [0] + clip.text.map { character in
      index += String(character).utf16.count
      return index
    }
    fullFace = makeOutlines ? Self.face(runs, before: Int.max) : nil
  }

  func draw(_ clip: Clip, animation: TextAnimation, frame: Int, in g: CGContext) {
    let progress = clip.textAnimationProgress(animation, at: frame)
    let count = graphemeEnds.count - 1
    let visible = animation.characters ? Int((Double(count) * progress + 1e-9).rounded(.down)) : count
    guard visible > 0 || (animation.underline && progress > 0 && underlineWidth > 0) else { return }
    let limit = visible >= count ? Int.max : graphemeEnds[visible]
    let face = visible == count ? fullFace : fullFace.map { _ in Self.face(runs, before: limit) }
    g.saveGState()
    let castsShadow = shadow?.enabled == true && (shadow?.opacity ?? 0) > 0
    if castsShadow, let shadow {
      setTextShadow(shadow, unit: unit, in: g)
      g.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    g.saveGState()
    g.scaleBy(x: scale, y: scale)
    g.textMatrix = .identity
    if animation.underline { drawUnderline(progress, in: g) }
    if let relief = clip.relief, let face { ReliefPaint.depth(face, relief, color, unit / scale, in: g) }
    if let outline = clip.textAppearance?.outline, outline.style != .none, let face {
      configureOutline(outline, width: max(0.5, outline.width * unit) / scale, in: g)
      g.addPath(face)
      g.strokePath()
    }
    for run in runs { run.draw(before: limit, in: g) }
    if let duotone = clip.textAppearance?.activeDuotone, let face {
      TextColorPaint.draw(duotone, face: face, reference: fullFace, in: g)
    } else if let relief = clip.relief, let face {
      ReliefPaint.front(face, relief, color, in: g)
    }
    g.restoreGState()
    if castsShadow { g.endTransparencyLayer() }
    g.restoreGState()
  }

  private func drawUnderline(_ progress: Double, in g: CGContext) {
    var remaining = underlineWidth * progress * progress * (3 - 2 * progress)
    g.setFillColor(color)
    for var line in underlines where remaining > 0 {
      let width = min(line.width, remaining)
      remaining -= line.width
      line.size.width = width
      let radius = min(line.width, line.height) / 2
      g.addPath(CGPath(roundedRect: line, cornerWidth: radius, cornerHeight: radius, transform: nil))
      g.fillPath()
    }
  }

  private static func face(_ runs: [Run], before limit: Int) -> CGPath {
    let path = CGMutablePath()
    for run in runs {
      for (index, outline) in zip(run.utf16Indices, run.outlines) where index < limit {
        if let outline { path.addPath(outline) }
      }
    }
    return path
  }
}
