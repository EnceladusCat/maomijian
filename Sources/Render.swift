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
private func artHeight(_ c: Clip, size: CGSize, style: CaptionStyle?) -> CGFloat {
  let original = size.height * c.h
  guard c.kind == .caption, let style else { return original }
  let unit = min(size.width, size.height) / 1080
  return max(original, (style.fontSize * 1.6 + style.outlineWidth * 2 + 18) * unit)
}
func artwork(_ c: Clip, size: CGSize, style: CaptionStyle? = nil) -> CGImage? {
  let w = max(2, Int((c.w * size.width).rounded()))
  let h = max(2, Int(artHeight(c, size: size, style: style).rounded()))
  guard let g = bitmap(w, h) else { return nil }
  let rect = CGRect(x: 0, y: 0, width: w, height: h)
  let col = ink(c.color)
  g.setFillColor(col)
  g.setStrokeColor(col)
  switch c.kind {
  case .rectangle, .ellipse:
    let line = max(2.0, size.height * 0.006)
    g.setLineWidth(line)
    let r = rect.insetBy(dx: line / 2, dy: line / 2)
    if c.kind == .rectangle { g.stroke(r) } else { g.strokeEllipse(in: r) }
  case .arrow:
    let neck = rect.width - min(rect.width * 0.45, rect.height * 1.25)
    let mid = rect.midY
    g.move(to: CGPoint(x: 0, y: mid * 0.73))
    g.addLine(to: CGPoint(x: neck, y: mid * 0.73))
    g.addLine(to: CGPoint(x: neck, y: 0))
    g.addLine(to: CGPoint(x: rect.width, y: mid))
    g.addLine(to: CGPoint(x: neck, y: rect.height))
    g.addLine(to: CGPoint(x: neck, y: mid * 1.27))
    g.addLine(to: CGPoint(x: 0, y: mid * 1.27))
    g.closePath()
    g.fillPath()
  case .text, .caption, .timer:
    let caption = c.kind == .caption ? style : nil
    let unit = min(size.width, size.height) / 1080
    let appearance = c.kind == .caption ? nil : c.textAppearance
    let outline = appearance?.outline
    let pad = min(
      max(2, rect.height * 0.07, (caption?.outlineWidth ?? outline?.width ?? 0) * unit),
      (min(rect.width, rect.height) - 1) / 2)

    let box = rect.insetBy(dx: pad, dy: pad)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byWordWrapping
    var fs =
      caption.map { $0.fontSize * unit } ?? appearance.map { $0.size * unit }
      ?? (rect.height * (c.kind == .caption ? 0.60 : 0.71))
    var setter: CTFramesetter!
    var measured = CGSize.zero
    for _ in 0..<32 {
      let pointSize = max(2, fs)
      let bold = caption?.bold ?? appearance?.bold ?? true
      let family = caption?.font ?? appearance?.font ?? ""
      var font = NSFont.systemFont(ofSize: pointSize, weight: bold ? .semibold : .regular)
      if !family.isEmpty,
        let custom = NSFontManager.shared.font(
          withFamily: family, traits: bold ? .boldFontMask : [],
          weight: bold ? 8 : 5, size: pointSize)
      {
        font = custom
      }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: caption.map { ink($0.foreground) } ?? col) ?? .white,
        .paragraphStyle: para,
      ]
      if let style = caption, style.outlineWidth > 0 {
        attributes[.strokeColor] = NSColor(cgColor: ink(style.outline))
        attributes[.strokeWidth] = -100 * style.outlineWidth * unit / pointSize
      }
      let attr = NSAttributedString(string: c.text, attributes: attributes)
      setter = CTFramesetterCreateWithAttributedString(attr)
      measured = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRangeMake(0, 0), nil,
        CGSize(width: box.width, height: CGFloat.greatestFiniteMagnitude), nil)
      if measured.height <= box.height { break }
      fs *= 0.87
    }
    if c.kind == .caption && !c.text.isEmpty {
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
    } else {
      g.setShadow(
        offset: CGSize(width: 0, height: -1), blur: max(1, fs * 0.08), color: ink("#000000", 0.8))
    }
    let rh = min(box.height, ceil(measured.height) + 1)
    let path = CGPath(
      rect: CGRect(x: box.minX, y: (rect.height - rh) / 2, width: box.width, height: rh),
      transform: nil)
    let textFrame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
    if let outline, outline.style != .none {
      traceGlyphs(textFrame, outline, origin: path.boundingBoxOfPath.origin, scale: unit, in: g)
    }
    CTFrameDraw(textFrame, g)
  default: return nil
  }
  return g.makeImage()
}
private func traceGlyphs(
  _ frame: CTFrame, _ outline: VisualBorder, origin: CGPoint, scale: CGFloat, in g: CGContext
) {
  let lines = CTFrameGetLines(frame) as! [CTLine]
  guard !lines.isEmpty else { return }
  var origins = [CGPoint](repeating: .zero, count: lines.count)
  CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
  let width = max(0.5, outline.width * scale)
  g.saveGState()
  g.setStrokeColor(ink(outline.color))
  g.setLineJoin(.round)
  g.setLineWidth(width * 2)
  if outline.style == .dashed { g.setLineDash(phase: 0, lengths: [3 * width, 2 * width]) }
  for (line, baseline) in zip(lines, origins) {
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard let font = attributes[kCTFontAttributeName] else { continue }
      for index in 0..<CTRunGetGlyphCount(run) {
        var glyph: CGGlyph = 0
        var position = CGPoint.zero
        CTRunGetGlyphs(run, CFRangeMake(index, 1), &glyph)
        CTRunGetPositions(run, CFRangeMake(index, 1), &position)
        var transform = CGAffineTransform(
          translationX: origin.x + baseline.x + position.x, y: origin.y + baseline.y + position.y)
        if let outlinePath = CTFontCreatePathForGlyph(font as! CTFont, glyph, &transform) {
          g.addPath(outlinePath)
          g.strokePath()
        }
      }
    }
  }
  g.restoreGState()
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
}
private func smear(_ image: CGImage, amount: Double) -> CGImage {
  guard amount >= 1, let a = bitmap(image.width, image.height),
    let b = bitmap(image.width, image.height), let src = a.data, let dst = b.data
  else { return image }
  a.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  var u = vImage_Buffer(
    data: src, height: UInt(image.height), width: UInt(image.width), rowBytes: a.bytesPerRow)
  var v = vImage_Buffer(
    data: dst, height: UInt(image.height), width: UInt(image.width), rowBytes: b.bytesPerRow)
  let kernel = UInt32(min(121, Int(amount) * 2 + 1))
  guard
    vImageBoxConvolve_ARGB8888(&u, &v, nil, 0, 0, 1, kernel, nil, vImage_Flags(kvImageEdgeExtend))
      == kvImageNoError
  else { return image }
  return b.makeImage() ?? image
}
final class FramePainter {
  let size: CGSize
  let project: Project
  private let preview: Bool
  private let motionPreview: FramePainter?
  private var artworks = [UUID: (text: String, image: CGImage)]()
  private let filteredStills: NSCache<NSUUID, CGImage> = {
    let cache = NSCache<NSUUID, CGImage>()
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()
  private let lock = NSLock()
  init(_ project: Project, _ size: CGSize, preview: Bool = false) {
    self.project = project
    self.size = size
    self.preview = preview
    let scale = 480 / min(size.width, size.height)
    if preview, scale < 1 {
      motionPreview = FramePainter(
        project,
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()),
        preview: true)
    } else {
      motionPreview = nil
    }
  }
  private func image(for c: Clip, at frame: Int) -> CGImage? {
    let text = c.displayedText(at: frame)
    lock.lock()
    defer { lock.unlock() }
    if let cached = artworks[c.id], cached.text == text { return cached.image }
    if artworks.count >= 48 { artworks.removeAll(keepingCapacity: true) }
    var drawing = c
    drawing.text = text
    guard let result = artwork(drawing, size: size, style: project.captionStyle) else { return nil }
    artworks[c.id] = (text, result)
    return result
  }
  private func footage(_ picture: Picture, clip: Clip, look: FootageFilter, amount: Double)
    -> CGImage
  {
    guard amount > 0, look == .neon || look == .vhs || look == .prism else { return picture.image }
    func filtered() -> CGImage {
      look == .prism
        ? ChromaticRadial.shift(picture.image, amount: amount)
        : FootageLook.image(picture.image, look: look, amount: amount)
    }
    guard picture.still else { return filtered() }
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

  func paint(
    _ g: CGContext, frame: Int, active: [Clip], sourceForCanvas source: (UUID, CGSize) -> Picture?
  ) {
    let videos = active.filter { $0.kind == .video }
    if let incoming = videos.last(where: { c in
      c.from != nil && c.blend > 0 && frame >= c.blendStart && frame < c.blendStart + c.blend
        && videos.contains(where: { $0.id == c.from })
    }) {
      let progress = bound(
        Double(frame - incoming.blendStart) / Double(max(1, incoming.blend - 1)), 0, 1)
      let cut = incoming.start + (incoming.fixedCutOffset ?? 0)
      let outgoing = active.filter { part in
        part.kind == .video ? part.id != incoming.id : part.start < cut
      }
      let entering = active.filter { part in
        part.kind == .video
          ? part.id != incoming.from
          : (incoming.fixedCutOffset != nil
            ? part.end > cut
            : part.start >= cut || part.end > cut + incoming.blend)
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
        let other = active.filter { $0.id != clip.id }
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

  private func paintTransition(
    _ look: TransitionLook, at frame: Int, progress: Double, outgoing: [Clip],
    entering: [Clip], in g: CGContext, source: (UUID, CGSize) -> Picture?
  ) {
    if progress <= 0 || progress >= 1 {
      paintScene(g, frame: frame, active: progress <= 0 ? outgoing : entering, source: source)
      return
    }
    let rect = CGRect(origin: .zero, size: size)
    // Keep the configured preview size for clear endpoints and other effects.
    if let reduced = motionPreview, look == .zoom || look == .shake,
      let surface = bitmap(Int(reduced.size.width), Int(reduced.size.height))
    {
      reduced.paintTransition(
        look, at: frame, progress: progress, outgoing: outgoing, entering: entering,
        in: surface, source: source)
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
      paintScene(g, frame: frame, active: progress < 0.5 ? outgoing : entering, source: source)
      return
    }
    func drawScene(_ parts: [Clip], in target: CGContext, rect: CGRect) {
      paintScene(scene, frame: frame, active: parts, source: source)
      if let image = scene.makeImage() { target.draw(image, in: rect) }
    }

    switch look {
    case .slide:
      let phase = SlidePhase(progress)
      let offset = (phase.travel * size.width).rounded()
      if offset < size.width {
        drawScene(outgoing, in: composite, rect: rect.offsetBy(dx: -offset, dy: 0))
      }
      if offset > 0 {
        drawScene(entering, in: composite, rect: rect.offsetBy(dx: size.width - offset, dy: 0))
      }
      if let image = composite.makeImage() {
        g.draw(smear(image, amount: size.width * 0.035 * phase.blur), in: rect)
      }
    case .flip:
      let travel = ease(progress)
      let edge = sin(travel * .pi)
      let width = max(1, size.width * abs(cos(travel * .pi)))
      let face = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
      composite.setFillColor(ink(project.background))
      composite.fill(rect)
      drawScene(travel < 0.5 ? outgoing : entering, in: composite, rect: face)
      composite.setFillColor(ink("#000000", edge * 0.45))
      composite.fill(face)
      if let image = composite.makeImage() {
        g.draw(smear(image, amount: size.width * 0.043 * edge), in: rect)
      }
    case .zoom:
      let mix = ease((progress - 0.36) / 0.28)
      if mix < 1 { drawScene(outgoing, in: composite, rect: rect) }
      if mix > 0 {
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
      paintScene(scene, frame: frame, active: progress <= 0.42 ? outgoing : entering, source: source)
      if let image = scene.makeImage() {
        TransitionEffects.shake(image, progress: progress, in: g, canvas: rect, preview: true)
      }
    case .dissolve, .warp, .glitch, .comparison, .fire, .shake:
      paintScene(scene, frame: frame, active: outgoing, source: source)
      guard let before = scene.makeImage() else { return }
      paintScene(scene, frame: frame, active: entering, source: source)
      guard let after = scene.makeImage() else { return }
      TransitionEffects.draw(
        look, before: before, after: after,
        progress: progress, in: g, scratch: composite, canvas: rect, preview: preview)
    }
  }
  private func paintScene(_ g: CGContext, frame: Int, active: [Clip], source: (UUID, CGSize) -> Picture?) {
    let W = size.width
    let H = size.height
    let r = CGRect(origin: .zero, size: size)
    g.saveGState()
    defer { g.restoreGState() }
    g.setFillColor(ink(project.background))
    g.fill(r)
    g.clip(to: r)
    g.translateBy(x: 0, y: H)
    g.scaleBy(x: 1, y: -1)
    g.interpolationQuality = .medium
    let videos = active.filter { $0.kind == .video }
    for c in videos {
      guard let p = source(c.id, size) else { continue }
      g.saveGState()
      let m = c.motionOffset(at: frame, size: size)
      let look = c.footageFilter ?? .none
      let amount = c.filterAmount ?? 1
      let im = footage(p, clip: c, look: look, amount: amount)
      let src = CGRect(x: 0, y: 0, width: im.width, height: im.height)
      let oriented = src.applying(p.transform)
      let layout = VisualGeometry(clip: c, canvas: size, aspect: oriented.width / oriented.height)
      g.translateBy(x: c.x * W + m.x, y: c.y * H + m.y)
      g.rotate(by: c.angle * .pi / 180)
      g.setAlpha(c.opacity)
      g.clip(to: layout.visible)
      g.saveGState()
      g.translateBy(x: layout.full.minX, y: layout.full.minY)
      g.scaleBy(x: layout.full.width / oriented.width, y: layout.full.height / oriented.height)
      g.translateBy(x: -oriented.minX, y: -oriented.minY)
      g.concatenate(p.transform)
      g.translateBy(x: 0, y: src.height)
      g.scaleBy(x: 1, y: -1)
      g.draw(im, in: src)
      g.restoreGState()
      FootageLook.drawOverlay(
        look, amount: amount, in: g, rect: layout.visible,
        frame: max(0, frame - c.start))
      if let border = c.visualBorder, border.style != .none {
        let line = min(
          border.width * min(W, H) / 1080, min(layout.visible.width, layout.visible.height))
        g.setStrokeColor(ink(border.color))
        g.setLineWidth(line)
        if border.style == .dashed { g.setLineDash(phase: 0, lengths: [4 * line, 2.5 * line]) }
        g.stroke(layout.visible.insetBy(dx: line / 2, dy: line / 2))
      }
      g.restoreGState()
    }
    for c in active.filter({ $0.kind.isArt && !$0.kind.isRegion && $0.kind != .caption })
      + active.filter({ $0.kind == .caption })
    {
      guard let im = image(for: c, at: frame) else { continue }
      let m = c.motionOffset(at: frame, size: size)
      let w = c.w * W
      let h = artHeight(c, size: size, style: project.captionStyle)
      g.saveGState()
      g.translateBy(x: c.x * W + m.x, y: c.y * H + m.y)
      g.rotate(by: c.angle * .pi / 180)
      g.setAlpha(c.opacity)
      g.scaleBy(x: 1, y: -1)
      g.draw(im, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
      g.restoreGState()
    }
    let lenses = active.filter { $0.kind == .zoom }
    if !lenses.isEmpty {
      g.flush()
      let patches = lenses.compactMap { lensPatch(for: $0, at: frame, in: g) }
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
        let stroke = max(1, min(W, H) * 0.0035)
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
    let lights = active.filter { $0.kind == .highlight }
    if let darkness = lights.map(\.opacity).max(), darkness > 0 {
      g.saveGState()
      for c in lights {
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

  }
}
