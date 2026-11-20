import CoreGraphics

enum ShapePaint {
  static func draw(
    _ clip: Clip, in rect: CGRect, canvas: CGSize, color: CGColor, context g: CGContext
  ) {
    let unit = min(canvas.width, canvas.height) / 1080
    let style = clip.shapeAppearance ?? ShapeAppearance()
    let hollow = clip.shapeFill == .hollow
    let frame = clip.relief == nil ? rect : ReliefPaint.faceRect(rect, unit: unit)
    let short = min(frame.width, frame.height)
    let width = style.outlineWidth.map { $0 * unit } ?? max(2, canvas.height * 0.006)
    let amplitude = style.edge == .rough ? min(short * 0.10, 15 * unit) * style.roughness : 0

    if hollow, clip.relief == nil, amplitude == 0, style.outlineWidth == nil {
      // Keep the original stroke for ordinary outlines already saved in projects.
      let bounds = rect.insetBy(dx: width / 2, dy: width / 2)
      g.setLineWidth(width)
      if clip.kind == .rectangle { g.stroke(bounds) } else { g.strokeEllipse(in: bounds) }
      return
    }

    let stroke = min(width, short * 0.45)
    let inset = amplitude + (hollow ? stroke / 2 : 0)
    let bounds = frame.insetBy(dx: inset, dy: inset)
    let path: CGPath
    if amplitude > 0 {
      path = clip.kind == .ellipse
        ? roughEllipse(bounds, amplitude: amplitude, unit: unit)
        : roughRectangle(bounds, amplitude: amplitude, unit: unit)
    } else {
      path = clip.kind == .ellipse
        ? CGPath(ellipseIn: bounds, transform: nil) : CGPath(rect: bounds, transform: nil)
    }

    if let relief = clip.relief {
      let face = hollow ? path.copy(strokingWithWidth: stroke, lineCap: .round,
        lineJoin: .round, miterLimit: 1) : path
      ReliefPaint.draw(face, relief, color, unit, in: g)
    } else if hollow {
      g.setLineWidth(stroke)
      g.setLineJoin(amplitude > 0 ? .round : .miter)
      g.addPath(path)
      g.strokePath()
    } else {
      g.addPath(path)
      g.fillPath()
    }
  }

  private static func roughRectangle(_ rect: CGRect, amplitude: CGFloat, unit: CGFloat) -> CGPath {
    let corners = [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
    let path = CGMutablePath()
    path.move(to: corners[0])
    for side in corners.indices {
      let start = corners[side], end = corners[(side + 1) % corners.count]
      let dx = end.x - start.x, dy = end.y - start.y
      let length = max(0.01, hypot(dx, dy))
      let count = bound(Int((length / max(1, 18 * unit)).rounded()), 5, 54)
      for i in 1..<count {
        let fraction = CGFloat(i) / CGFloat(count)
        let distance = grit(side * 83 + i) * amplitude
        path.addLine(to: CGPoint(x: start.x + dx * fraction + dy / length * distance,
                                 y: start.y + dy * fraction - dx / length * distance))
      }
      path.addLine(to: end)
    }
    path.closeSubpath()
    return path
  }

  private static func roughEllipse(_ rect: CGRect, amplitude: CGFloat, unit: CGFloat) -> CGPath {
    let rx = rect.width / 2, ry = rect.height / 2
    let count = bound(Int(((rx + ry) * .pi / max(1, 18 * unit)).rounded()), 24, 160)
    let path = CGMutablePath()
    for i in 0..<count {
      let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
      let x = cos(angle), y = sin(angle)
      let nx = x * ry, ny = y * rx
      let distance = grit(i) * amplitude / max(0.01, hypot(nx, ny))
      let point = CGPoint(x: rect.midX + rx * x + nx * distance, y: rect.midY + ry * y + ny * distance)
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }

  // Use the same contour on every frame so a static shape never shimmers.
  private static func grit(_ index: Int) -> CGFloat {
    let hash = (index &* 1_103_515_245 &+ 12_345) ^ ((index &* 48271) >> 1)
    let rough = CGFloat((hash >> 12) & 255) / 127.5 - 1
    return rough * 0.75 + sin(CGFloat(index) * 0.63) * 0.25
  }
}
