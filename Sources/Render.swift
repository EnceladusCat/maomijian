import Accelerate
import AppKit
import CoreGraphics
import CoreText

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bgra = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
func bitmap(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer? = nil, row: Int? = nil) -> CGContext?
{
  CGContext(
    data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row ?? w * 4, space: rgb,
    bitmapInfo: bgra)
}
func ink(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
  let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
  return CGColor(
    srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
    blue: CGFloat(v & 255) / 255, alpha: alpha)
}
func textFont(_ family: String, bold: Bool, size: CGFloat) -> NSFont {
  if !family.isEmpty, let font = NSFontManager.shared.font(
    withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 8 : 5, size: size)
  {
    return font
  }
  return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

func setTextShadow(_ shadow: TextShadow, unit: CGFloat, in g: CGContext) {
  g.setShadow(offset: CGSize(width: shadow.x * unit, height: -shadow.y * unit),
              blur: shadow.blur * unit, color: ink(shadow.color, shadow.opacity))
}

// Shape glyphs at a normal font size and draw them into the output canvas.
// Increasing the authored size never allocates a larger bitmap.
private struct FixedText {
  private let lines: [(CTLine, CGPoint)]
  private let face: CGPath?
  init(_ text: String, appearance: TextAppearance, color: CGColor, relief: ReliefStyle?) {
    lines = fixedTextLines(text, appearance: appearance, color: color)
    face = relief != nil || appearance.activeDuotone != nil ? glyphFace(lines) : nil
  }

  func draw(
    _ appearance: TextAppearance, unit: CGFloat, relief: ReliefStyle?, color: CGColor,
    in g: CGContext
  ) {
    // Keep Core Graphics coordinates representable even for numbers far beyond the canvas.
    let scale = min(appearance.size / fixedTextPointSize * unit, 65536)
    let shadow = appearance.shadow ?? TextShadow()
    let useShadow = shadow.enabled && shadow.opacity > 0
    g.saveGState()
    if useShadow {
      setTextShadow(shadow, unit: unit, in: g)
      g.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    g.saveGState()
    g.scaleBy(x: scale, y: scale)
    g.textMatrix = .identity
    if let relief, let face { ReliefPaint.depth(face, relief, color, unit / scale, in: g) }
    let outline = appearance.outline
    if outline.style != .none {
      configureOutline(outline, width: max(0.5, outline.width * unit) / scale, in: g)
      for (line, baseline) in lines { traceGlyphs(line, baseline: baseline, in: g) }
    }
    for (line, baseline) in lines {
      g.textPosition = baseline
      CTLineDraw(line, g)
    }
    if let duotone = appearance.activeDuotone, let face {
      TextColorPaint.draw(duotone, face: face, in: g)
    } else if let relief, let face {
      ReliefPaint.front(face, relief, color, in: g)
    }
    g.restoreGState()
    if useShadow { g.endTransparencyLayer() }
    g.restoreGState()
  }
}

let fixedTextPointSize = 64.0

func fixedTextLines(
  _ text: String, appearance: TextAppearance, color: CGColor, animateCharacters: Bool = false
) -> [(CTLine, CGPoint)] {
  let font = textFont(appearance.font, bold: appearance.bold, size: fixedTextPointSize)
  var attributes: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor(cgColor: color) ?? .white,
  ]
  if animateCharacters { attributes[.ligature] = 0 }
  let rows = text.components(separatedBy: "\n")
  let spacing = font.ascender - font.descender + font.leading
  let top = Double(rows.count - 1) * spacing / 2 - (font.ascender + font.descender) / 2
  return rows.enumerated().map { index, row in
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    return (line, CGPoint(x: -width / 2, y: top - Double(index) * spacing))
  }
}

struct WrappedText {
  let frame: CTFrame
  let origin: CGPoint
  let measured: CGSize
  let fontSize: CGFloat
  let padding: CGFloat
  var lines: [(CTLine, CGPoint)] { textLines(frame, origin: origin) }

  init(_ c: Clip, in rect: CGRect, unit: CGFloat, style: CaptionStyle? = nil) {
    let caption = c.kind == .caption ? style : nil
    let appearance = c.kind == .caption ? nil : c.textAppearance
    let outline = appearance?.outline
    let col = ink(c.color)
    let relief = c.relief
    let pad = min(
      max(2, rect.height * 0.07, (caption?.outlineWidth ?? outline?.width ?? 0) * unit,
          relief == nil ? 0 : 16 * unit),
      (min(rect.width, rect.height) - 1) / 2)

    let box = rect.insetBy(dx: pad, dy: pad)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byWordWrapping
    var fs =
      caption.map { $0.fontSize * unit } ?? appearance.map { $0.size * unit }
      ?? (rect.height * (c.kind == .caption ? (c.captionTranslation == nil ? 0.60 : 0.30) : 0.71))
    let text = c.kind == .caption ? c.captionText : c.text
    var setter: CTFramesetter!
    var measured = CGSize.zero
    for _ in 0..<32 {
      let pointSize = max(2, fs)
      let bold = caption?.bold ?? appearance?.bold ?? true
      let family = caption?.font ?? appearance?.font ?? ""
      var attributes: [NSAttributedString.Key: Any] = [
        .font: textFont(family, bold: bold, size: pointSize),
        .foregroundColor: NSColor(cgColor: caption.map { ink($0.foreground) } ?? col) ?? .white,
        .paragraphStyle: para,
      ]
      if let style = caption, style.outlineWidth > 0 {
        attributes[.strokeColor] = NSColor(cgColor: ink(style.outline))
        attributes[.strokeWidth] = -100 * style.outlineWidth * unit / pointSize
      }
      if c.kind == .text && c.textAnimation?.characters == true { attributes[.ligature] = 0 }
      let attr = NSAttributedString(string: text, attributes: attributes)
      setter = CTFramesetterCreateWithAttributedString(attr)
      measured = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRangeMake(0, 0), nil,
        CGSize(width: box.width, height: CGFloat.greatestFiniteMagnitude), nil)
      if measured.height <= box.height { break }
      fs *= 0.87
    }
    let rh = min(box.height, ceil(measured.height) + 1)
    let path = CGPath(
      rect: CGRect(x: box.minX, y: (rect.height - rh) / 2, width: box.width, height: rh),
      transform: nil)
    frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
    origin = path.boundingBoxOfPath.origin
    self.measured = measured
    fontSize = fs
    padding = pad
  }
}

private func captionBaseHeight(_ c: Clip, size: CGSize, style: CaptionStyle?) -> CGFloat {
  let original = size.height * c.h
  guard c.kind == .caption, let style else { return original }
  let unit = min(size.width, size.height) / 1080
  return max(original, (style.fontSize * 1.6 + style.outlineWidth * 2 + 18) * unit)
}

func artworkBounds(_ c: Clip, size: CGSize, style: CaptionStyle?) -> CGRect {
  let width = c.w * size.width
  let base = captionBaseHeight(c, size: size, style: style)
  let height = c.kind == .caption && c.captionTranslation != nil ? min(base * 2, max(base, size.height)) : base
  // Keep the lower edge in the same place when a second language is added.
  return CGRect(x: -width / 2, y: -base / 2, width: width, height: height)
}
func artwork(_ c: Clip, size: CGSize, style: CaptionStyle? = nil, waitingForReveal: Bool = false) -> CGImage? {
  let w = max(2, Int((c.w * size.width).rounded()))
  let h = max(2, Int(artworkBounds(c, size: size, style: style).height.rounded()))
  guard let g = bitmap(w, h) else { return nil }
  let rect = CGRect(x: 0, y: 0, width: w, height: h)
  let col = ink(c.color)
  let relief = c.relief
  g.setFillColor(col)
  g.setStrokeColor(col)
  switch c.kind {
  case .editorial:
    guard let spec = c.editorial else { return nil }
    EditorialPaint.draw(spec, title: c.text, accent: c.color, in: rect,
                        progress: waitingForReveal ? 0 : 1, context: g)
  case .rectangle, .ellipse:
    ShapePaint.draw(c, in: rect, canvas: size, color: col, context: g)
  case .arrow:
    let unit = min(size.width, size.height) / 1080
    let face = relief == nil ? rect : ReliefPaint.faceRect(rect, unit: unit)
    let neck = face.maxX - min(face.width * 0.45, face.height * 1.25)
    let mid = face.midY, stem = face.height * 0.135
    let path = CGMutablePath()
    path.addLines(between: [
      CGPoint(x: face.minX, y: mid - stem), CGPoint(x: neck, y: mid - stem),
      CGPoint(x: neck, y: face.minY), CGPoint(x: face.maxX, y: mid),
      CGPoint(x: neck, y: face.maxY), CGPoint(x: neck, y: mid + stem),
      CGPoint(x: face.minX, y: mid + stem),
    ])
    path.closeSubpath()
    if let relief {
      ReliefPaint.draw(path, relief, col, unit, in: g)
    } else {
      g.addPath(path)
      g.fillPath()
    }
  case .text, .caption, .timer:
    let caption = c.kind == .caption ? style : nil
    let unit = min(size.width, size.height) / 1080
    let appearance = c.kind == .caption ? nil : c.textAppearance
    let outline = appearance?.outline
    let layout = WrappedText(c, in: rect, unit: unit, style: style)
    let pad = layout.padding
    let measured = layout.measured
    if c.kind == .caption && !c.captionText.isEmpty {
      let bw = min(rect.width, max(10, measured.width + 4 * pad))
      let bh = min(rect.height, measured.height + 2 * pad)
      let back = CGRect(x: (rect.width - bw) / 2, y: (rect.height - bh) / 2, width: bw, height: bh)
      let radius = min(min(bw, bh) / 2, caption.map { $0.radius * unit } ?? pad)
      let path = CGPath(
        roundedRect: back, cornerWidth: radius, cornerHeight: radius, transform: nil)
      g.setFillColor(ink(caption?.background ?? "#111827", caption?.backgroundOpacity ?? 0.82))
      g.addPath(path)
      g.fillPath()
      if let style = caption, style.border != .none {
        let line = style.borderWidth * unit
        let innerRadius = max(0, radius - line / 2)
        g.setStrokeColor(ink(style.borderColor))
        g.setLineWidth(line)
        if style.border == .dashed { g.setLineDash(phase: 0, lengths: [3 * line, 2 * line]) }
        g.addPath(
          CGPath(
            roundedRect: back.insetBy(dx: line / 2, dy: line / 2), cornerWidth: innerRadius,
            cornerHeight: innerRadius, transform: nil))
        g.strokePath()
      }
    } else if appearance?.shadow == nil && relief == nil {
      g.setShadow(
        offset: CGSize(width: 0, height: -1), blur: max(1, layout.fontSize * 0.08), color: ink("#000000", 0.8))
    }
    let textFrame = layout.frame
    let origin = layout.origin
    let duotone = c.kind == .text ? appearance?.activeDuotone : nil
    let face = relief != nil || duotone != nil ? glyphFace(layout.lines) : nil
    if let relief, let face { ReliefPaint.depth(face, relief, col, unit, in: g) }
    if let outline, outline.style != .none {
      traceGlyphs(textFrame, outline, origin: origin, scale: unit, in: g)
    }
    CTFrameDraw(textFrame, g)
    if let duotone, let face {
      g.setShadow(offset: .zero, blur: 0, color: nil)
      TextColorPaint.draw(duotone, face: face, in: g)
    } else if let relief, let face {
      ReliefPaint.front(face, relief, col, in: g)
    }
  default: return nil
  }
  return g.makeImage()
}
private func traceGlyphs(
  _ frame: CTFrame, _ outline: VisualBorder, origin: CGPoint, scale: CGFloat, in g: CGContext
) {
  g.saveGState()
  configureOutline(outline, width: max(0.5, outline.width * scale), in: g)
  for (line, baseline) in textLines(frame, origin: origin) { traceGlyphs(line, baseline: baseline, in: g) }
  g.restoreGState()
}

private func textLines(_ frame: CTFrame, origin: CGPoint) -> [(CTLine, CGPoint)] {
  let lines = CTFrameGetLines(frame) as! [CTLine]
  guard !lines.isEmpty else { return [] }
  var origins = [CGPoint](repeating: .zero, count: lines.count)
  CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
  return zip(lines, origins).map { ($0, CGPoint(x: origin.x + $1.x, y: origin.y + $1.y)) }
}

private func glyphFace(_ lines: [(CTLine, CGPoint)]) -> CGPath {
  let path = CGMutablePath()
  for (line, baseline) in lines { visitGlyphs(line, baseline: baseline) { path.addPath($0) } }
  return path
}

func configureOutline(_ outline: VisualBorder, width: CGFloat, in g: CGContext) {
  g.setStrokeColor(ink(outline.color))
  g.setLineJoin(.round)
  g.setLineWidth(width * 2)
  if outline.style == .dashed { g.setLineDash(phase: 0, lengths: [3 * width, 2 * width]) }
}

private func traceGlyphs(_ line: CTLine, baseline: CGPoint, in g: CGContext) {
  visitGlyphs(line, baseline: baseline) {
    g.addPath($0)
    g.strokePath()
  }
}

private func visitGlyphs(_ line: CTLine, baseline: CGPoint, _ visit: (CGPath) -> Void) {
  for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let attributes = CTRunGetAttributes(run) as NSDictionary
    guard let font = attributes[kCTFontAttributeName] else { continue }
    for index in 0..<CTRunGetGlyphCount(run) {
      var glyph: CGGlyph = 0
      var position = CGPoint.zero
      CTRunGetGlyphs(run, CFRangeMake(index, 1), &glyph)
      CTRunGetPositions(run, CFRangeMake(index, 1), &position)
      var transform = CGAffineTransform(translationX: baseline.x + position.x, y: baseline.y + position.y)
      if let outlinePath = CTFontCreatePathForGlyph(font as! CTFont, glyph, &transform) {
        visit(outlinePath)
      }
    }
  }
}

struct Picture {
  let image: CGImage
  var transform = CGAffineTransform.identity
  var still = false
}
private func ease(_ p: Double) -> Double {
  let t = bound(p, 0, 1)
  return t * t * (3 - 2 * t)
}
struct SlidePhase {
  let travel: Double, blur: Double
  init(_ t: Double) {
    travel = ease((t - 0.26) / 0.67)
    blur = ease(t / 0.24) * (1 - ease((t - 0.76) / 0.24))
  }
  var overlap: Double { min(0.46, min(travel, 1 - travel) * 1.2) }
}
private func smear(_ image: CGImage, amount: Double) -> CGImage {
  guard amount >= 1, let a = bitmap(image.width, image.height) else { return image }
  a.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return horizontalExposure(a, radius: amount) ?? image
}
private func horizontalExposure(_ a: CGContext, radius: Double) -> CGImage? {
  guard radius >= 1, let b = bitmap(a.width, a.height),
    let src = a.data, let dst = b.data
  else { return nil }
  var u = vImage_Buffer(
    data: src, height: UInt(a.height), width: UInt(a.width), rowBytes: a.bytesPerRow)
  var v = vImage_Buffer(
    data: dst, height: UInt(a.height), width: UInt(a.width), rowBytes: b.bytesPerRow)
  let kernel = UInt32(min((a.width - 1) / 2, Int(radius)) * 2 + 1)
  guard
    vImageBoxConvolve_ARGB8888(&u, &v, nil, 0, 0, 1, kernel, nil, vImage_Flags(kvImageEdgeExtend))
      == kvImageNoError
  else { return nil }
  return b.makeImage()
}
private let slideFeather = CGGradient(
  colorsSpace: rgb, colors: [ink("#FFFFFF", 0), ink("#FFFFFF")] as CFArray, locations: [0, 1])!
final class FramePainter {
  let size: CGSize
  let project: Project
  private let preview: Bool
  private let motionPreview: FramePainter?
  private let artworkJoins: [UUID: [Project.Join]]
  private let groupedArtwork: [UUID: [Clip]]
  private let clipOrder: [UUID: Int]
  private let trackDepth: [UUID: Int]?
  private let audioSignals: [UUID: AudioSignalTrack]
  private var animatedText = [UUID: (Clip, AnimatedTextLayout)]()
  private var artworks = [UUID: (text: String, waiting: Bool, image: CGImage)]()
  private var textLayouts = [UUID: (text: String, appearance: TextAppearance, color: String, layout: FixedText)]()
  private var chartLayouts = [UUID: (
    spec: ChartSpec, aspect: Double, color: String, appearance: ChartAppearance?, layout: ChartLayout)]()
  private let finishedCharts: NSCache<NSUUID, CGImage> = {
    let cache = NSCache<NSUUID, CGImage>()
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()
  private let filteredStills: NSCache<NSUUID, CGImage> = {
    let cache = NSCache<NSUUID, CGImage>()
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()
  private let lock = NSLock()
  init(_ project: Project, _ size: CGSize, preview: Bool = false, audioSignals: [UUID: AudioSignalTrack] = [:]) {
    self.project = project
    self.size = size
    self.preview = preview
    self.audioSignals = audioSignals
    trackDepth = project.visualTrackDepth()
    var links: [UUID: [Project.Join]] = [:]
    for join in project.artworkJoins where join.active {
      links[join.before.id, default: []].append(join)
      links[join.after.id, default: []].append(join)
    }
    artworkJoins = links
    var artworkByGroup: [UUID: [Clip]] = [:]
    for clip in project.clips where !clip.kind.isMedia {
      if let group = clip.groupID { artworkByGroup[group, default: []].append(clip) }
    }
    groupedArtwork = artworkByGroup
    clipOrder = artworkByGroup.isEmpty ? [:] : Dictionary(
      uniqueKeysWithValues: project.clips.enumerated().map { ($0.element.id, $0.offset) })
    let scale = 480 / min(size.width, size.height)
    if preview, scale < 1 {
      motionPreview = FramePainter(
        project,
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()),
        preview: true, audioSignals: audioSignals)
    } else {
      motionPreview = nil
    }
  }
  private func image(for c: Clip, at frame: Int, waitingForReveal: Bool = false) -> CGImage? {
    let text = c.displayedText(at: frame)
    lock.lock()
    defer { lock.unlock() }
    if let cached = artworks[c.id], cached.text == text, cached.waiting == waitingForReveal { return cached.image }
    if artworks.count >= 48 { artworks.removeAll(keepingCapacity: true) }
    var drawing = c
    drawing.text = text
    guard let result = artwork(drawing, size: size, style: project.captionStyle,
                               waitingForReveal: waitingForReveal) else { return nil }
    artworks[c.id] = (text, waitingForReveal, result)
    return result
  }
  private func layout(for c: Clip, appearance: TextAppearance, at frame: Int) -> FixedText {
    let text = c.displayedText(at: frame)
    return lock.withLock {
      if let cached = textLayouts[c.id], cached.text == text, cached.appearance == appearance,
        cached.color == c.color
      {
        return cached.layout
      }
      if textLayouts.count >= 48 { textLayouts.removeAll(keepingCapacity: true) }
      let layout = FixedText(text, appearance: appearance, color: ink(c.color), relief: c.relief)
      textLayouts[c.id] = (text, appearance, c.color, layout)
      return layout
    }
  }
  private func animationLayout(for clip: Clip) -> AnimatedTextLayout {
    lock.withLock {
      if let (original, layout) = animatedText[clip.id], original == clip { return layout }
      if animatedText.count >= 48 { animatedText.removeAll(keepingCapacity: true) }
      let layout = AnimatedTextLayout(clip, canvas: size)
      animatedText[clip.id] = (clip, layout)
      return layout
    }
  }
  private func footage(
    _ picture: Picture, clip: Clip, filters: [ClipFilter], cacheable: Bool
  ) -> CGImage {
    let styles = filters.filter { $0.amount > 0 && $0.look != .camera }
    guard !styles.isEmpty else { return picture.image }
    func filtered() -> CGImage {
      styles.reduce(picture.image) { image, filter in
        switch filter.look {
        case .prism: return ChromaticRadial.shift(image, amount: filter.amount)
        case .backgroundKey:
          return BackgroundKey.image(image, sensitivity: filter.sensitivity, strength: filter.amount, color: filter.keyColor)
        default: return FootageLook.image(image, look: filter.look, amount: filter.amount)
        }
      }
    }
    guard picture.still, cacheable else { return filtered() }
    let key = clip.id as NSUUID
    if let cached = filteredStills.object(forKey: key) { return cached }
    let rendered = filtered()
    filteredStills.setObject(rendered, forKey: key, cost: rendered.bytesPerRow * rendered.height)
    return rendered
  }
  private struct LensPatch {
    let clip: Clip, box: CGRect, destination: CGRect, image: CGImage, amount: Double
  }
  private func lensPatch(for clip: Clip, at frame: Int, in g: CGContext) -> LensPatch? {
    let amount = clip.zoomAmount(at: frame)
    guard amount > 0, let source = g.data else { return nil }
    let box = clip.shape.fit(clip.region, in: size).applying(
      CGAffineTransform(scaleX: size.width, y: size.height))
    let factor = 1 + (clip.scale - 1) * amount
    let xScale = CGFloat(g.width) / size.width
    let yScale = CGFloat(g.height) / size.height
    let src = CGRect(
      x: (box.midX - box.width / (2 * factor)) * xScale,
      y: (box.midY - box.height / (2 * factor)) * yScale, width: box.width * xScale / factor,
      height: box.height * yScale / factor)
    let pixels = src.integral.intersection(CGRect(x: 0, y: 0, width: g.width, height: g.height))
    let w = Int(pixels.width)
    let h = Int(pixels.height)
    let row = w * 4
    guard w > 0, h > 0, let bytes = NSMutableData(length: row * h) else { return nil }
    let start = source.advanced(by: Int(pixels.minY) * g.bytesPerRow + Int(pixels.minX) * 4)
    for y in 0..<h {
      memcpy(bytes.mutableBytes.advanced(by: y * row), start.advanced(by: y * g.bytesPerRow), row)
    }
    guard let provider = CGDataProvider(data: bytes),
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: rgb,
        bitmapInfo: CGBitmapInfo(rawValue: bgra), provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    // Snapshot all source patches before drawing any of them, including overlapping lenses.
    let sx = box.width / src.width
    let sy = box.height / src.height
    let dest = CGRect(
      x: (pixels.minX - src.minX) * sx, y: (src.maxY - pixels.maxY) * sy, width: pixels.width * sx,
      height: pixels.height * sy)
    return LensPatch(clip: clip, box: box, destination: dest, image: image, amount: amount)
  }
  func paint(_ g: CGContext, frame: Int, active: [Clip], source: (UUID) -> Picture?) {
    paint(g, frame: frame, active: active, sourceForCanvas: { id, _ in source(id) })
  }

  private func holdingArtwork(
    _ parts: [Clip], of video: Clip, at cut: Int, side: ClipEnd
  ) -> [Clip] {
    guard let group = video.groupID, let artwork = groupedArtwork[group] else { return parts }
    let held = artwork.filter {
      side == .head ? $0.start == cut : $0.end == cut
    }
    guard !held.isEmpty else { return parts }
    let present = Set(parts.map(\.id))
    // Retain the authored layer order when a transition borrows a group's edge frame.
    return (parts + held.filter { !present.contains($0.id) }).sorted {
      clipOrder[$0.id, default: Int.max] < clipOrder[$1.id, default: Int.max]
    }
  }

  func paint(
    _ g: CGContext, frame: Int, active: [Clip], sourceForCanvas source: (UUID, CGSize) -> Picture?
  ) {
    let videos = backToFront(active.filter { $0.kind == .video })
    if let incoming = videos.last(where: { c in
      c.from != nil && c.blend > 0 && frame >= c.blendStart && frame < c.blendStart + c.blend
        && videos.contains(where: { $0.id == c.from })
    }), let previous = videos.first(where: { $0.id == incoming.from }) {
      let progress = bound(
        Double(frame - incoming.blendStart) / Double(max(1, incoming.blend - 1)), 0, 1)
      let cut = incoming.start + (incoming.fixedCutOffset ?? 0)
      var outgoing = active.filter { part in
        part.kind == .video ? part.id != incoming.id : part.start < cut
      }
      var entering = active.filter { part in
        part.kind == .video
          ? part.id != incoming.from
          : (incoming.fixedCutOffset != nil
            ? part.end > cut
            : part.start >= cut || part.end > cut + incoming.blend)
      }
      if incoming.fixedCutOffset != nil {
        if frame >= cut { outgoing = holdingArtwork(outgoing, of: previous, at: cut, side: .tail) }
        else { entering = holdingArtwork(entering, of: incoming, at: cut, side: .head) }
      }
      paintTransition(
        incoming.transitionStyle, at: frame, progress: progress, outgoing: outgoing,
        entering: entering, in: g, source: source)
      return
    }
    for clip in videos.reversed() where clip.startEffect != nil || clip.endEffect != nil {
      for side in ClipEnd.allCases {
        guard let span = clip.transitionRange(at: side), span.contains(frame),
          let look = clip.effect(at: side)?.style
        else { continue }
        let other = active.filter { part in
          if part.id == clip.id { return false }
          guard let group = clip.groupID, part.groupID == group, !part.kind.isMedia else {
            return true
          }
          return side == .head ? part.start < clip.start : part.end > clip.end
        }
        let progress = Double(frame - span.lowerBound) / Double(max(1, span.count - 1))
        paintTransition(
          look, at: frame, progress: progress,
          outgoing: side == .head ? other : active,
          entering: side == .head ? active : other,
          in: g, source: source)
        return
      }
    }
    paintScene(g, frame: frame, active: active, source: source)
  }

  private func backToFront(_ clips: [Clip]) -> [Clip] {
    guard let trackDepth else { return clips }
    return clips.sorted { trackDepth[$0.id, default: Int.max] > trackDepth[$1.id, default: Int.max] }
  }

  private func paintTransition(
    _ look: TransitionLook, at frame: Int, progress: Double, outgoing: [Clip],
    entering: [Clip], in g: CGContext, artworkOnly: Bool = false,
    source: (UUID, CGSize) -> Picture?
  ) {
    func paint(_ clips: [Clip], in target: CGContext) {
      if artworkOnly {
        target.saveGState()
        prepareCanvas(target)
        for clip in clips { paintArtwork(clip, frame: frame, in: target) }
        target.restoreGState()
      } else {
        paintScene(target, frame: frame, active: clips, source: source)
      }
    }
    if progress <= 0 || progress >= 1 {
      paint(progress <= 0 ? outgoing : entering, in: g)
      return
    }
    let rect = CGRect(origin: .zero, size: size)
    // Keep erasing and additive blends on the transition's own transparent layer.
    if artworkOnly { g.beginTransparencyLayer(auxiliaryInfo: nil) }
    defer { if artworkOnly { g.endTransparencyLayer() } }
    if look == .unfold {
      paint(outgoing, in: g)
      let opening = rect.insetBy(dx: rect.width * (1 - ease(progress)) / 2, dy: 0)
      g.saveGState()
      g.clip(to: opening)
      if artworkOnly { g.clear(rect) }
      // A zoom lens reads neighboring pixels, so it needs the full entering scene.
      if entering.contains(where: { $0.kind == .zoom }),
        let scene = bitmap(Int(size.width), Int(size.height))
      {
        paint(entering, in: scene)
        if let image = scene.makeImage() { g.draw(image, in: rect) }
      } else {
        paint(entering, in: g)
      }
      g.restoreGState()
      return
    }
    // Keep the configured preview size for clear endpoints and other effects.
    if let reduced = motionPreview, look == .zoom || look == .shake,
      let surface = bitmap(Int(reduced.size.width), Int(reduced.size.height))
    {
      reduced.paintTransition(
        look, at: frame, progress: progress, outgoing: outgoing, entering: entering,
        in: surface, artworkOnly: artworkOnly, source: source)
      if let image = surface.makeImage() {
        g.saveGState()
        g.interpolationQuality = .low
        g.draw(image, in: rect)
        g.restoreGState()
        return
      }
    }
    guard let composite = bitmap(Int(size.width), Int(size.height)),
      let scene = bitmap(Int(size.width), Int(size.height))
    else {
      paint(progress < 0.5 ? outgoing : entering, in: g)
      return
    }
    func snapshot(_ parts: [Clip]) -> CGImage? {
      if artworkOnly { scene.clear(rect) }
      paint(parts, in: scene)
      return scene.makeImage()
    }
    func drawScene(_ parts: [Clip], in target: CGContext, rect: CGRect) {
      if let image = snapshot(parts) { target.draw(image, in: rect) }
    }

    switch look {
    case .unfold:
      break
    case .slide:
      let phase = SlidePhase(progress)
      let seam = size.width * (1 - phase.travel)
      let half = size.width * phase.overlap / 2
      let left = (seam - half).rounded()
      let right = (seam + half).rounded()
      if right > 0 {
        drawScene(outgoing, in: composite, rect: rect.offsetBy(dx: right - size.width, dy: 0))
      }
      if left < size.width {
        if right > left { composite.beginTransparencyLayer(auxiliaryInfo: nil) }
        drawScene(entering, in: composite, rect: rect.offsetBy(dx: left, dy: 0))
        if right > left {
          composite.saveGState()
          composite.setBlendMode(.destinationIn)
          composite.drawLinearGradient(
            slideFeather, start: CGPoint(x: left, y: 0), end: CGPoint(x: right, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
          composite.restoreGState()
          composite.endTransparencyLayer()
        }
      }
      if let image = composite.makeImage() {
        let radius = size.width * 0.059 * phase.blur
        g.draw(horizontalExposure(composite, radius: radius) ?? image, in: rect)
        if radius >= 1 {
          g.saveGState()
          g.setAlpha(0.22 * phase.blur)
          g.draw(image, in: rect)
          g.restoreGState()
        }
      }
    case .flip:
      let travel = ease(progress)
      let edge = sin(travel * .pi)
      let width = max(1, size.width * abs(cos(travel * .pi)))
      let face = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
      if !artworkOnly {
        composite.setFillColor(ink(project.background))
        composite.fill(rect)
      }
      drawScene(travel < 0.5 ? outgoing : entering, in: composite, rect: face)
      if artworkOnly { composite.setBlendMode(.sourceAtop) }
      composite.setFillColor(ink("#000000", edge * 0.45))
      composite.fill(face)
      if let image = composite.makeImage() {
        g.draw(smear(image, amount: min(60, size.width * 0.043 * edge)), in: rect)
      }
    case .zoom:
      let mix = ease((progress - 0.36) / 0.28)
      if mix < 1 {
        if artworkOnly { composite.setAlpha(1 - mix) }
        drawScene(outgoing, in: composite, rect: rect)
      }
      if mix > 0 {
        if artworkOnly { composite.setBlendMode(.plusLighter) }
        composite.setAlpha(mix)
        drawScene(entering, in: composite, rect: rect)
      }
      guard let image = composite.makeImage() else { return }
      let peak = pow(sin(progress * .pi), 2)
      let zoom = 1 + 1.35 * peak
      let trail = 0.45 * peak
      g.saveGState()
      if preview { g.interpolationQuality = .none }
      let samples = preview ? 3 : 4
      for sample in 0..<samples {
        let scale = zoom - trail * Double(sample) / Double(samples - 1)
        let expanded = rect.insetBy(
          dx: -(scale - 1) * rect.width / 2,
          dy: -(scale - 1) * rect.height / 2)
        g.setAlpha(1 / Double(sample + 1))
        g.draw(image, in: expanded)
      }
      g.restoreGState()
    case .shake where preview && (progress <= 0.42 || progress >= 0.58):
      // The fade is fully opaque on one side outside the middle of the shake.
      if let image = snapshot(progress <= 0.42 ? outgoing : entering) {
        TransitionEffects.shake(image, progress: progress, in: g, canvas: rect, preview: true)
      }
    case .dissolve, .warp, .glitch, .comparison, .fire, .shake:
      guard let before = snapshot(outgoing), let after = snapshot(entering) else { return }
      TransitionEffects.draw(
        look, before: before, after: after,
        progress: progress, in: g, scratch: composite, canvas: rect, preview: preview,
        transparent: artworkOnly)
    }
  }
  func paintCaptions(_ g: CGContext, frame: Int, active: [Clip]) {
    g.saveGState()
    defer { g.restoreGState() }
    prepareCanvas(g)
    for clip in active where clip.kind == .caption { paintArtwork(clip, frame: frame, in: g) }
  }

  private func prepareCanvas(_ g: CGContext) {
    g.clip(to: CGRect(origin: .zero, size: size))
    g.translateBy(x: 0, y: size.height)
    g.scaleBy(x: 1, y: -1)
    g.interpolationQuality = .medium
  }

  private func paintArtwork(_ c: Clip, frame: Int, in g: CGContext) {
    let W = size.width
    let H = size.height
    let sample = bound(frame, c.start, c.end - 1)
    let placement = c.placement(at: sample, canvas: size)
    g.saveGState()
    g.translateBy(x: placement.center.x, y: placement.center.y)
    g.rotate(by: c.angle * .pi / 180)
    g.setAlpha(c.opacity)
    g.scaleBy(x: placement.scale, y: -placement.scale)
    let unit = min(W, H) / 1080
    if let style = c.audioVisualization, c.kind == .audioVisual {
      if let source = style.source, let track = audioSignals[source] {
        let levels = track.levels(at: sample, style: style)
        let w = c.w * W, h = c.h * H
        AudioVisualPaint.draw(levels, style: style, color: c.color,
                              in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), context: g)
      }
    } else if let spec = c.editorial, c.kind == .editorial {
      let w = c.w * W, h = c.h * H
      let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
      let progress = spec.progress(frame: sample, clip: c)
      let opacity = c.opacity * spec.exitOpacity(frame: sample, clip: c)
      let waiting = progress == 0 && spec.activeMetricReveal != nil
      if opacity > 0, progress >= 1 || waiting, let image = image(for: c, at: sample, waitingForReveal: waiting) {
        g.setAlpha(opacity)
        g.draw(image, in: rect)
      } else if opacity > 0 {
        g.setAlpha(opacity)
        if opacity < 1 { g.beginTransparencyLayer(auxiliaryInfo: nil) }
        EditorialPaint.draw(spec, title: c.text, accent: c.color, in: rect, progress: progress, context: g)
        if opacity < 1 { g.endTransparencyLayer() }
      }
    } else if let chart = c.chart, c.kind == .chart {
      let w = c.w * W, h = c.h * H
      paintChart(c, spec: chart, progress: chart.progress(at: sample, in: c),
                 frame: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), in: g)
    } else if c.kind == .text, let animation = c.textAnimation, animation.enabled {
      animationLayout(for: c).draw(c, animation: animation, frame: sample, in: g)
    } else if (c.kind == .text || c.kind == .timer), var appearance = c.textAppearance, appearance.usesFixedSize {
      if c.kind != .text { appearance.duotone = nil }
      layout(for: c, appearance: appearance, at: sample)
        .draw(appearance, unit: unit, relief: c.relief, color: ink(c.color), in: g)
    } else if let image = image(for: c, at: sample) {
      if let shadow = c.textAppearance?.shadow, shadow.enabled && shadow.opacity > 0 {
        setTextShadow(shadow, unit: unit, in: g)
      }
      g.draw(image, in: artworkBounds(c, size: size, style: project.captionStyle))
    }
    g.restoreGState()
  }

  private func paintChart(_ c: Clip, spec: ChartSpec, progress: Double, frame: CGRect, in g: CGContext) {
    let aspect = Double(frame.width / frame.height)
    let layout = lock.withLock {
      if let cached = chartLayouts[c.id], cached.spec == spec, cached.aspect == aspect,
        cached.color == c.color, cached.appearance == c.chartAppearance
      {
        return cached.layout
      }
      if chartLayouts.count >= 8 { chartLayouts.removeAll(keepingCapacity: true) }
      let layout = ChartLayout(spec, color: c.color, aspect: aspect, appearance: c.chartAppearance)
      chartLayouts[c.id] = (spec, aspect, c.color, c.chartAppearance, layout)
      return layout
    }
    if progress >= 1 {
      if let image = finishedCharts.object(forKey: layout.id) {
        g.draw(image, in: layout.fitted(to: frame))
        return
      }
      if let image = layout.snapshot() {
        finishedCharts.setObject(image, forKey: layout.id, cost: image.bytesPerRow * image.height)
        g.draw(image, in: layout.fitted(to: frame))
        return
      }
    }
    layout.draw(in: frame, progress: progress, context: g)
  }

  func backgroundKeyPreview(_ clip: Clip, picture: Picture, frame: Int, filterIndex: Int) -> CGImage? {
    let stack = clip.filters
    guard stack.indices.contains(filterIndex), stack[filterIndex].look == .backgroundKey,
      let g = bitmap(Int(size.width), Int(size.height)) else { return nil }
    var input = clip
    input.filters = Array(stack.prefix(filterIndex))
    input.opacity = 1
    prepareCanvas(g)
    paintFootage(input, picture: picture, frame: frame, in: g, decorations: false)
    return g.makeImage()
  }

  private func paintFootage(_ c: Clip, picture p: Picture, frame: Int, in g: CGContext, decorations: Bool = true) {
    g.saveGState()
    defer { g.restoreGState() }
    var cacheable = decorations
    let filters = c.filters.map { filter in
      var current = filter
      current.amount = c.filterIntensity(filter, at: frame)
      if filter.look != .camera && current.amount != filter.amount { cacheable = false }
      return current
    }
    let im = footage(p, clip: c, filters: filters, cacheable: cacheable)
    let src = CGRect(x: 0, y: 0, width: im.width, height: im.height)
    let oriented = src.applying(p.transform)
    let layout = VisualGeometry(clip: c, canvas: size, aspect: oriented.width / oriented.height)
    let placement = c.placement(at: frame, canvas: size, geometry: layout)
    g.translateBy(x: placement.center.x, y: placement.center.y)
    g.rotate(by: c.angle * .pi / 180)
    g.scaleBy(x: placement.scale, y: placement.scale)
    g.setAlpha(c.opacity)
    if let inset = c.pictureInset {
      g.addPath(inset.shape.path(layout.visible))
      g.clip()
    } else { g.clip(to: layout.visible) }
    let matteOverlays = decorations && filters.contains { $0.look == .backgroundKey && $0.amount > 0 }
      && filters.contains { $0.look == .vhs && $0.amount > 0 }
    if matteOverlays { g.beginTransparencyLayer(auxiliaryInfo: nil) }
    g.saveGState()
    g.translateBy(x: layout.full.minX, y: layout.full.minY)
    g.scaleBy(x: layout.full.width / oriented.width, y: layout.full.height / oriented.height)
    g.translateBy(x: -oriented.minX, y: -oriented.minY)
    g.concatenate(p.transform)
    g.translateBy(x: 0, y: src.height)
    g.scaleBy(x: 1, y: -1)
    g.draw(im, in: src)
    g.restoreGState()
    guard decorations else { return }
    for filter in filters {
      if matteOverlays && filter.look == .vhs { g.setBlendMode(.sourceAtop) }
      FootageLook.drawOverlay(
        filter.look, amount: filter.amount, in: g, rect: layout.visible,
        frame: max(0, frame - c.start))
      if matteOverlays && filter.look == .vhs { g.setBlendMode(.normal) }
    }
    if matteOverlays { g.endTransparencyLayer() }
    if let border = c.visualBorder, border.style != .none {
      let line = min(
        border.width * min(size.width, size.height) / 1080, min(layout.visible.width, layout.visible.height))
      g.setStrokeColor(ink(border.color))
      g.setLineWidth(line)
      if border.style == .dashed { g.setLineDash(phase: 0, lengths: [4 * line, 2.5 * line]) }
      let frame = layout.visible.insetBy(dx: line / 2, dy: line / 2)
      if let inset = c.pictureInset {
        g.addPath(inset.shape.path(frame))
        g.strokePath()
      } else { g.stroke(frame) }
    }
  }

  private func paintArtworkTransition(
    _ c: Clip, frame: Int, active: [Clip], in g: CGContext, source: (UUID, CGSize) -> Picture?
  ) {
    func paint(_ look: TransitionLook, span: Range<Int>, before: [Clip], after: [Clip]) {
      let progress = Double(frame - span.lowerBound) / Double(max(1, span.count - 1))
      g.saveGState()
      defer { g.restoreGState() }
      // The transition painter takes a bottom-up context; artwork is normally drawn top-down.
      g.translateBy(x: 0, y: size.height)
      g.scaleBy(x: 1, y: -1)
      paintTransition(
        look, at: frame, progress: progress, outgoing: before, entering: after,
        in: g, artworkOnly: true, source: source)
    }
    if let join = artworkJoins[c.id]?.first(where: { $0.range.contains(frame) }),
      let before = active.first(where: { $0.id == join.before.id }),
      let after = active.first(where: { $0.id == join.after.id })
    {
      if c.id == (frame < join.frame ? before.id : after.id) {
        paint(after.transitionStyle, span: join.range, before: [before], after: [after])
      }
      return
    }
    if c.startEffect != nil || c.endEffect != nil {
      for side in ClipEnd.allCases {
        guard let span = c.transitionRange(at: side), span.contains(frame),
          let look = c.effect(at: side)?.style
        else { continue }
        paint(look, span: span, before: side == .tail ? [c] : [], after: side == .head ? [c] : [])
        return
      }
    }
    paintArtwork(c, frame: frame, in: g)
  }

  private func paintScene(_ g: CGContext, frame: Int, active: [Clip], source: (UUID, CGSize) -> Picture?) {
    let W = size.width
    let H = size.height
    let r = CGRect(origin: .zero, size: size)
    g.saveGState()
    defer { g.restoreGState() }
    g.setFillColor(ink(project.background))
    g.fill(r)
    prepareCanvas(g)
    func paintVideo(_ c: Clip) {
      if let picture = source(c.id, size) { paintFootage(c, picture: picture, frame: frame, in: g) }
    }
    func paintLenses(_ lenses: [Clip]) {
      guard !lenses.isEmpty else { return }
      g.flush()
      let patches = lenses.compactMap { lensPatch(for: $0, at: bound(frame, $0.start, $0.end - 1), in: g) }
      for patch in patches {
        let clip = patch.clip
        let box = patch.box
        let path = clip.shape.path(box)
        g.saveGState()
        g.addPath(path)
        g.clip()
        g.translateBy(x: box.minX, y: box.maxY)
        g.scaleBy(x: 1, y: -1)
        g.draw(patch.image, in: patch.destination)
        g.restoreGState()
        let stroke = min(
          min(box.width, box.height) / 2,
          clip.lensBorderWidth.map { $0 * min(W, H) / 1080 } ?? max(1, min(W, H) * 0.0035))
        guard stroke > 0 else { continue }
        g.saveGState()
        g.addPath(path)
        g.clip()
        g.setStrokeColor(ink(clip.border, patch.amount))
        g.setLineWidth(stroke)
        g.addPath(clip.shape.path(box.insetBy(dx: stroke / 2, dy: stroke / 2)))
        g.strokePath()
        g.restoreGState()
      }
    }
    func paintHighlights(_ lights: [Clip]) {
      let active = lights.map { ($0, $0.highlightOpacity(at: bound(frame, $0.start, $0.end - 1))) }
        .filter { $0.1 > 0 }
      guard let darkness = active.map({ $0.1 }).max() else { return }
      g.saveGState()
      for (c, _) in active {
        g.beginPath()
        g.addRect(r)
        g.addPath(
          c.shape.path(c.shape.fit(c.region, in: size).applying(CGAffineTransform(scaleX: W, y: H)))
        )
        g.clip(using: .evenOdd)
      }
      g.setFillColor(ink("#000000", darkness))
      g.fill(r)
      g.restoreGState()
    }

    if trackDepth != nil {
      for clip in backToFront(active) {
        switch clip.kind {
        case .video: paintVideo(clip)
        case .zoom: paintLenses([clip])
        case .highlight: paintHighlights([clip])
        case .audio, .caption: break
        default: paintArtworkTransition(clip, frame: frame, active: active, in: g, source: source)
        }
      }
    } else {
      for clip in active where clip.kind == .video && clip.pictureInset == nil { paintVideo(clip) }
      for clip in active where clip.kind.isArt && !clip.kind.isRegion && clip.kind != .caption {
        paintArtworkTransition(clip, frame: frame, active: active, in: g, source: source)
      }
      paintLenses(active.filter { $0.kind == .zoom })
      let lights = active.filter { $0.kind == .highlight }
      paintHighlights(lights.filter { $0.highlightFadeIn != true && $0.highlightFadeOut != true })
      for light in lights where light.highlightFadeIn == true || light.highlightFadeOut == true {
        paintHighlights([light])
      }
      for clip in active where clip.kind == .video && clip.pictureInset != nil { paintVideo(clip) }
    }
    for clip in active where clip.kind == .caption { paintArtwork(clip, frame: frame, in: g) }
  }
}
