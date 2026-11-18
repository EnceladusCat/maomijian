import CoreGraphics
import CoreImage
import Foundation

enum TransitionEffects {
  private static let ci = CIContext(options: [.cacheIntermediates: false])

  static func draw(
    _ style: TransitionLook, before: CGImage, after: CGImage,
    progress: Double, in out: CGContext, scratch: CGContext, canvas: CGRect, preview: Bool = false
  ) {
    let pulse = sin(progress * .pi)
    let width = canvas.width
    let height = canvas.height
    let short = min(width, height)
    switch style {
    case .dissolve:
      crossfade(before, after, mix: eased(progress), in: out, rect: canvas)
    case .warp:
      crossfade(before, after, mix: eased((progress - 0.27) / 0.46), in: scratch, rect: canvas)
      guard let combined = scratch.makeImage() else { return }
      let zoom = canvas.insetBy(dx: -0.34 * width * pulse, dy: -0.34 * height * pulse)
      let image = CIImage(cgImage: combined)
      let center = CIVector(x: image.extent.midX, y: image.extent.midY)
      let angle = 1.65 * pulse * cos(progress * .pi * 0.8)
      let warped = image.clampedToExtent().applyingFilter(
        "CITwirlDistortion",
        parameters: [
          kCIInputCenterKey: center, kCIInputRadiusKey: short * 0.68, kCIInputAngleKey: angle,
        ]
      ).cropped(to: image.extent)
      if let rendered = ci.createCGImage(warped, from: image.extent) {
        out.draw(rendered, in: zoom)
      } else {
        // Shear each strip around the same center when Core Image is unavailable.
        let strips = 32
        for row in 0..<strips {
          let y = Double(row) / Double(strips)
          let band = CGRect(x: 0, y: y * height, width: width, height: height / Double(strips))
          let shear = sin((y - 0.5) * .pi * 2) * angle * width * 0.095
          out.saveGState()
          out.clip(to: band)
          out.draw(combined, in: zoom.offsetBy(dx: shear, dy: 0))
          out.restoreGState()
        }
      }
    case .glitch:
      let mix = eased((progress - 0.32) / 0.36)
      crossfade(before, after, mix: mix, in: scratch, rect: canvas)
      guard let base = scratch.makeImage() else { return }
      out.draw(ChromaticRadial.shift(base, amount: pulse * 0.78), in: canvas)
      let tick = Int(progress * 29)
      let colors = ["#F844A6", "#4BFBF2", "#C0F449"]
      for index in 0..<11 {
        let y = jitter(tick * 31 + index * 11)
        let h = (0.004 + 0.095 * pow(jitter(index * 19 + tick * 3), 3)) * height * pulse
        let band = CGRect(x: 0, y: y * height, width: width, height: max(1, h))
        let shift = (jitter(43 + index * 13 + tick) - 0.5) * width * 0.20 * pulse
        out.saveGState()
        out.clip(to: band)
        out.draw(
          index % 4 == 0 ? (progress < 0.5 ? after : before) : base,
          in: canvas.insetBy(dx: -abs(shift), dy: 0).offsetBy(dx: shift, dy: 0))
        out.setBlendMode(.screen)
        out.setFillColor(ink(colors[(tick + index) % colors.count], 0.18 * pulse))
        out.fill(band)
        out.restoreGState()
      }
    case .comparison:
      out.draw(before, in: canvas)
      let halfSlant = width * 0.21
      let thickness = max(2, short * 0.024)
      let margin = halfSlant + thickness
      let x = eased(progress) * (width + 2 * margin) - margin
      out.saveGState()
      out.move(to: CGPoint(x: -margin, y: 0))
      out.addLine(to: CGPoint(x: x - halfSlant, y: 0))
      out.addLine(to: CGPoint(x: x + halfSlant, y: height))
      out.addLine(to: CGPoint(x: -margin, y: height))
      out.closePath()
      out.clip()
      out.draw(after, in: canvas)
      out.restoreGState()
      out.setStrokeColor(ink("#FFFFFF"))
      out.setLineWidth(thickness)
      out.move(to: CGPoint(x: x - halfSlant, y: 0))
      out.addLine(to: CGPoint(x: x + halfSlant, y: height))
      out.strokePath()
    case .fire:
      fire(before, after, progress: progress, in: out, canvas: canvas)
    case .shake:
      crossfade(before, after, mix: eased((progress - 0.42) / 0.16), in: scratch, rect: canvas)
      guard let combined = scratch.makeImage() else { return }
      shake(combined, progress: progress, in: out, canvas: canvas, preview: preview)
    default:
      out.draw(before, in: canvas)
    }
  }

  static func shake(
    _ image: CGImage, progress: Double, in out: CGContext, canvas: CGRect, preview: Bool
  ) {
    let width = canvas.width
    let height = canvas.height
    let peak = pow(sin(progress * .pi), 0.72)
    let zoom = canvas.insetBy(dx: -width * peak * 0.24, dy: -height * peak * 0.24)
      .offsetBy(dx: -canvas.midX, dy: -canvas.midY)
    out.saveGState()
    defer { out.restoreGState() }
    if preview { out.interpolationQuality = .none }
    // Nearby positions give the shake a directional exposure trail.
    let samples = preview ? 3 : 5
    for sample in 0..<samples {
      let t = progress + (Double(sample) / Double(samples - 1) - 0.5) * 0.031 * peak
      let x = width * peak * (sin(t * .pi * 19) * 0.077 + sin(t * .pi * 37) * 0.020)
      let y = height * peak * (cos(t * .pi * 23) * 0.080 + sin(t * .pi * 29) * 0.031)
      out.saveGState()
      out.setAlpha(1 / Double(sample + 1))
      out.translateBy(x: canvas.midX + x, y: canvas.midY + y)
      out.rotate(by: sin(t * .pi * 21) * 0.087 * peak)
      out.draw(image, in: zoom)
      out.restoreGState()
    }
  }

  private static func eased(_ t: Double) -> Double {
    let t = bound(t, 0, 1)
    return t * t * (3 - 2 * t)
  }

  private static func crossfade(
    _ before: CGImage, _ after: CGImage, mix: Double,
    in g: CGContext, rect: CGRect
  ) {
    g.draw(before, in: rect)
    g.saveGState()
    g.setAlpha(mix)
    g.draw(after, in: rect)
    g.restoreGState()
  }

  private static func jitter(_ seed: Int) -> Double {
    let n = UInt32(truncatingIfNeeded: seed) &* 747_796_405 &+ 2_891_336_453
    let mixed = ((n >> ((n >> 28) &+ 4)) ^ n) &* 277_803_737
    return Double((mixed >> 22) ^ mixed) / Double(UInt32.max)
  }

  private static func fire(
    _ before: CGImage, _ after: CGImage, progress: Double,
    in g: CGContext, canvas: CGRect
  ) {
    let width = canvas.width
    let height = canvas.height
    let heat = pow(sin(progress * .pi), 0.58)
    let front = height * (eased(progress) * 1.56 - 0.28)
    let phase = progress * 10
    let points = (0...80).map { i -> CGPoint in
      let u = Double(i) / 80
      let tongues = pow(max(0, sin(u * 68 + phase)), 3) * 0.12
      let wobble = 0.04 * sin(u * 21 - phase) + 0.026 * cos(u * 113 + phase * 2)
      return CGPoint(x: u * width, y: front + height * heat * (tongues + wobble))
    }
    g.draw(before, in: canvas)
    g.saveGState()
    g.addLines(between: [.zero] + points + [CGPoint(x: width, y: 0)])
    g.closePath()
    g.clip()
    g.draw(after, in: canvas)
    g.restoreGState()
    let layers = [
      (0.095, 0.07, "#B5340D", 0.38),
      (0.047, 0.045, "#F5590F", 0.9),
      (0.028, 0.019, "#FFAA2F", 0.98),
      (0.014, 0.006, "#FFF0A3", 0.91),
    ]
    for (rise, fall, color, alpha) in layers {
      let up = points.enumerated().map { i, point in
        point.offset(
          y: rise * height * heat * (0.33 + 0.67 * pow(abs(sin(Double(i) * 0.29 + phase)), 2)))
      }
      let down = points.reversed().map { $0.offset(y: -fall * height * heat) }
      g.setFillColor(ink(color, alpha * heat))
      g.beginPath()
      g.addLines(between: up + down)
      g.closePath()
      g.fillPath()
    }
    g.setFillColor(ink("#FFE484", 0.85 * heat))
    for spark in 0..<32 {
      let drift = jitter(27 + spark * 17)
      let time = (progress * (2 + drift) + drift).truncatingRemainder(dividingBy: 1)
      let x = jitter(11 + spark * 23) * width + time * width * 0.046
      let y = front + (time * 0.27 - 0.08) * height * heat
      let radius = max(0.5, min(width, height) * (0.001 + 0.002 * drift))
      g.fillEllipse(in: CGRect(x: x, y: y, width: radius * 2, height: radius * 3.3))
    }
  }
}
extension CGPoint {
  fileprivate func offset(y delta: CGFloat) -> CGPoint { CGPoint(x: x, y: y + delta) }
}
