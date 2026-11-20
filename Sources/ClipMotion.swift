import CoreGraphics

struct ClipPlacement {
  let center: CGPoint
  let scale: CGFloat
  let anchorsToCanvas: Bool
}

extension Clip {
  func placement(at frame: Int, canvas: CGSize, geometry: VisualGeometry? = nil) -> ClipPlacement {
    let position = CGPoint(x: x * canvas.width, y: y * canvas.height)
    let offset = motionOffset(at: frame, size: canvas)
    guard motion.isZoom, length > 1 else {
      return ClipPlacement(center: CGPoint(x: position.x + offset.x, y: position.y + offset.y),
                           scale: 1, anchorsToCanvas: false)
    }
    let target = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
    let minimum = geometry.flatMap { $0.minimumCoverScale(center: target, at: position, degrees: angle, canvas: canvas) }
    let pivot = minimum == nil ? position : target
    let strength = motionZoom ?? 1.22
    let age = Double(max(0, frame - start))
    let progress: Double
    if motionContinuous == true {
      progress = (1 - cos(age * 2 * .pi / Double(motionFrames))) / 2
    } else {
      let t = min(1, age / Double(min(motionFrames, length - 1)))
      progress = t * t * (3 - 2 * t)
    }
    let scale: CGFloat
    if motion == .pushIn {
      scale = 1 + (strength - 1) * progress
    } else {
      let end = max(1 / strength, minimum ?? 0)
      let start = end * strength
      scale = start + (end - start) * progress
    }
    return ClipPlacement(
      center: CGPoint(x: pivot.x + (position.x - pivot.x) * scale + offset.x,
                      y: pivot.y + (position.y - pivot.y) * scale + offset.y),
      scale: scale, anchorsToCanvas: minimum != nil)
  }
}

extension VisualGeometry {
  // Project all four canvas corners onto the rotated source axes. Scale around
  // the canvas center so an off-center crop can still cover the same corners.
  fileprivate func minimumCoverScale(
    center: CGPoint, at position: CGPoint, degrees: Double, canvas: CGSize
  ) -> Double? {
    let radians = degrees * .pi / 180
    let local = CGPoint(x: center.x - position.x, y: center.y - position.y)
      .applying(CGAffineTransform(rotationAngle: -radians))
    let (c, s): (CGFloat, CGFloat) = (abs(cos(CGFloat(radians))), abs(sin(CGFloat(radians))))
    let radiusX = (c * canvas.width + s * canvas.height) / 2
    let radiusY = (s * canvas.width + c * canvas.height) / 2
    let roomX = min(local.x - visible.minX, visible.maxX - local.x)
    let roomY = min(local.y - visible.minY, visible.maxY - local.y)
    guard roomX > 0, roomY > 0 else { return nil }
    let minimum = max(radiusX / roomX, radiusY / roomY)
    return minimum <= 1 + 1e-8 ? min(minimum, 1) : nil
  }
}
