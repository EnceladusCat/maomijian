import CoreGraphics

enum BrandMark {
  private static let silhouette: CGPath = {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 11, y: 21))
    path.addQuadCurve(to: CGPoint(x: 17, y: 17), control: CGPoint(x: 12, y: 13))
    path.addLine(to: CGPoint(x: 35, y: 31))
    path.addLine(to: CGPoint(x: 65, y: 31))
    path.addLine(to: CGPoint(x: 83, y: 17))
    path.addQuadCurve(to: CGPoint(x: 89, y: 21), control: CGPoint(x: 88, y: 13))
    path.addLine(to: CGPoint(x: 94, y: 55))
    path.addQuadCurve(to: CGPoint(x: 90, y: 65), control: CGPoint(x: 96, y: 61))
    path.addLine(to: CGPoint(x: 74, y: 79))
    path.addQuadCurve(to: CGPoint(x: 64, y: 83), control: CGPoint(x: 69, y: 83))
    path.addLine(to: CGPoint(x: 36, y: 83))
    path.addQuadCurve(to: CGPoint(x: 26, y: 79), control: CGPoint(x: 31, y: 83))
    path.addLine(to: CGPoint(x: 10, y: 65))
    path.addQuadCurve(to: CGPoint(x: 6, y: 55), control: CGPoint(x: 4, y: 61))
    path.closeSubpath()
    return path
  }()

  static func draw(in rect: CGRect, context g: CGContext) {
    let side = min(rect.width, rect.height)
    guard side > 0 else { return }
    g.saveGState()
    defer { g.restoreGState() }
    g.translateBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
    g.scaleBy(x: side / 100, y: side / 100)
    g.addPath(silhouette)
    g.clip()
    g.setFillColor(color(0xC8B8FF))
    g.fill(CGRect(x: 0, y: 0, width: 100, height: 100))

    fill([(64, 31), (89, 12), (100, 59), (78, 86), (35, 86), (56, 70)], color: 0xAA9AF6, in: g)
    fill([(7, 64), (33, 73), (63, 74), (93, 63), (80, 86), (20, 86)], color: 0x9987E5, in: g)
    fill([(17, 24), (30, 34), (15, 40)], color: 0xE7DEFF, in: g)
    fill([(83, 24), (70, 34), (85, 40)], color: 0xD6CBFF, in: g)

    fill([(25, 48), (41, 50), (38, 58), (28, 57)], color: 0x23253D, in: g)
    fill([(75, 48), (59, 50), (62, 58), (72, 57)], color: 0x23253D, in: g)
    fill([(46, 61), (57, 66.5), (46, 72)], color: 0xBDE8D1, in: g)
  }

  private static func fill(_ points: [(CGFloat, CGFloat)], color hex: UInt32, in g: CGContext) {
    g.beginPath()
    g.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
    g.closePath()
    g.setFillColor(color(hex))
    g.fillPath()
  }

  private static func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}
