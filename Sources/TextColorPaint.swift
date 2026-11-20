import CoreGraphics

enum TextColorPaint {
  static func draw(_ style: TextDuotone, face: CGPath, reference: CGPath? = nil, in g: CGContext) {
    guard !face.isEmpty else { return }
    let box = (reference ?? face).boundingBoxOfPath
    let angle = style.angle * .pi / 180
    let nx = sin(angle), ny = cos(angle)
    let span = abs(nx) * box.width / 2 + abs(ny) * box.height / 2
    let edge = span * (1 - 2 * style.position)
    let extent = hypot(box.width, box.height)
    func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
      CGPoint(x: box.midX + nx * along + ny * across, y: box.midY + ny * along - nx * across)
    }
    g.saveGState()
    if style.position > 0 && style.position < 1 {
      g.addPath(face)
      g.clip()
      g.setFillColor(ink(style.secondColor))
      g.fill(box)
      g.beginPath()
      g.addLines(between: [point(edge, -extent), point(edge, extent),
                           point(extent, extent), point(extent, -extent)])
      g.closePath()
      g.setFillColor(ink(style.firstColor))
      g.fillPath()
    } else {
      g.setFillColor(ink(style.position == 0 ? style.secondColor : style.firstColor))
      g.addPath(face)
      g.fillPath()
    }
    g.restoreGState()
  }
}
