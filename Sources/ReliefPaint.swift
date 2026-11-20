import CoreGraphics

enum ReliefPaint {
  static func faceRect(_ rect: CGRect, unit: CGFloat) -> CGRect {
    let margin = min(16 * unit, min(rect.width, rect.height) / 4)
    return rect.insetBy(dx: margin, dy: margin)
  }

  static func draw(
    _ face: CGPath, _ style: ReliefStyle, _ tint: CGColor, _ unit: CGFloat, in g: CGContext
  ) {
    depth(face, style, tint, unit, in: g)
    front(face, style, tint, in: g)
  }

  static func depth(
    _ face: CGPath, _ style: ReliefStyle, _ tint: CGColor, _ unit: CGFloat, in g: CGContext
  ) {
    guard !face.isEmpty else { return }
    let inset: CGFloat = style == .chrome ? 9 : 13
    let shadow = ink(style == .neon ? "#13064E" : "#11213A")
    for step in (1...7).reversed() {
      let progress = CGFloat(step) / 7
      g.saveGState()
      g.translateBy(x: inset * unit * progress * 0.78, y: -inset * unit * progress)
      g.setFillColor(mix(tint, shadow, 0.48 + progress * 0.45))
      g.addPath(face)
      g.fillPath()
      g.restoreGState()
    }
    if style == .neon {
      g.saveGState()
      g.setLineJoin(.round)
      let glow = mix(tint, ink("#7D5BFF"), 0.72)
      g.setStrokeColor(glow.copy(alpha: 0.32) ?? glow)
      for width in [10.0, 6.0, 3.0] {
        g.setLineWidth(width * unit)
        g.addPath(face)
        g.strokePath()
      }
      g.restoreGState()
    }
  }

  static func front(_ face: CGPath, _ style: ReliefStyle, _ tint: CGColor, in g: CGContext) {
    let rect = face.boundingBoxOfPath
    guard !face.isEmpty, rect.height > 0 else { return }
    let colors: [CGColor]
    let stops: [CGFloat]
    switch style {
    case .flat: return
    case .extrusion:
      colors = [mix(tint, ink("#FFFFFF"), 0.52), tint, mix(tint, ink("#692F82"), 0.32)]
      stops = [0, 0.44, 1]
    case .chrome:
      colors = [ink("#FFFFFF"), mix(tint, ink("#E5EDFC"), 0.76), ink("#3B4568"),
                mix(tint, ink("#8EABCB"), 0.64), ink("#EFF8FF")]
      stops = [0, 0.43, 0.48, 0.55, 1]
    case .neon:
      colors = [mix(tint, ink("#FBCEFF"), 0.84), mix(tint, ink("#FD4CD9"), 0.74),
                mix(tint, ink("#804FFF"), 0.74), ink("#58EDFA")]
      stops = [0, 0.45, 0.69, 1]
    }
    guard let gradient = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: stops)
    else { return }
    g.saveGState()
    g.addPath(face)
    g.clip()
    g.drawLinearGradient(
      gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
      end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    g.restoreGState()
  }

  private static func mix(_ tint: CGColor, _ target: CGColor, _ amount: CGFloat) -> CGColor {
    let a = tint.components ?? [1, 1, 1]
    let b = target.components ?? [1, 1, 1]
    return CGColor(srgbRed: a[0] + (b[0] - a[0]) * amount,
                   green: a[1] + (b[1] - a[1]) * amount,
                   blue: a[2] + (b[2] - a[2]) * amount, alpha: 1)
  }
}
