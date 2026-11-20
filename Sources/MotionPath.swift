import CoreGraphics

struct MotionPath: Codable, Equatable {
  static let maximumSamples = 384
  private(set) var offsets: [CGPoint]
  private(set) var lower = 0.0
  private(set) var upper = 1.0

  init?(stroke: [CGPoint], in canvas: CGSize) {
    guard stroke.count >= 2, canvas.width > 0, canvas.height > 0,
      stroke.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
    else { return nil }
    let points = stroke.map { CGPoint(x: bound($0.x, 0, canvas.width), y: bound($0.y, 0, canvas.height)) }
    let origin = points[0]
    var smooth = points
    for i in 1..<(points.count - 1) {
      smooth[i].x = 0.18 * points[i - 1].x + 0.64 * points[i].x + 0.18 * points[i + 1].x
      smooth[i].y = 0.18 * points[i - 1].y + 0.64 * points[i].y + 0.18 * points[i + 1].y
    }
    var distances = [0.0]
    for i in 1..<smooth.count {
      distances.append(distances[i - 1] + hypot(smooth[i].x - smooth[i - 1].x, smooth[i].y - smooth[i - 1].y))
    }
    let length = distances[distances.count - 1]
    guard length.isFinite, length >= 6 else { return nil }
    let intervals = Int(min(Double(Self.maximumSamples - 1), ceil(length / 2)))
    var segment = 1
    // Equidistant samples give a constant drawing speed and O(1) positioning on each frame.
    offsets = (0...intervals).map { index in
      if index == 0 { return .zero }
      if index == intervals { return Self.normalizedOffset(smooth[smooth.count - 1], from: origin, in: canvas) }
      let distance = length * Double(index) / Double(intervals)
      while distances[segment] < distance { segment += 1 }
      let span = distances[segment] - distances[segment - 1]
      let t = span > 0 ? (distance - distances[segment - 1]) / span : 0
      let point = Self.interpolate(smooth[segment - 1], smooth[segment], t)
      return Self.normalizedOffset(point, from: origin, in: canvas)
    }
  }

  var valid: Bool {
    (2...Self.maximumSamples).contains(offsets.count) && offsets.first == .zero
      && (0...1).contains(lower) && (lower...1).contains(upper)
      && offsets.allSatisfy { (-1...1).contains($0.x) && (-1...1).contains($0.y) }
  }

  func at(_ progress: Double) -> CGPoint {
    sample(lower + (upper - lower) * bound(progress, 0, 1))
  }

  func portion(from first: Double, through last: Double) -> Self {
    var copy = self
    copy.lower = lower + (upper - lower) * bound(first, 0, 1)
    copy.upper = lower + (upper - lower) * bound(last, 0, 1)
    return copy
  }

  var guide: [CGPoint] {
    let intervals = Double(offsets.count - 1)
    let first = Int(floor(lower * intervals)) + 1
    let last = Int(ceil(upper * intervals))
    let interior = first < last ? Array(offsets[first..<last]) : []
    return [sample(lower)] + interior + [sample(upper)]
  }

  private func sample(_ progress: Double) -> CGPoint {
    let index = progress * Double(offsets.count - 1)
    let first = Int(index)
    if first >= offsets.count - 1 { return offsets[offsets.count - 1] }
    return Self.interpolate(offsets[first], offsets[first + 1], index - Double(first))
  }

  private static func normalizedOffset(_ point: CGPoint, from origin: CGPoint, in canvas: CGSize) -> CGPoint {
    CGPoint(x: (point.x - origin.x) / canvas.width, y: (point.y - origin.y) / canvas.height)
  }

  private static func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
  }
}

extension Clip {
  func pathProgress(at frame: Int) -> Double {
    length <= 1 ? 0 : bound(Double(frame - start) / Double(length - 1), 0, 1)
  }

  func pathMotion(in range: Range<Int>) -> MotionPath? {
    motionPath?.portion(from: pathProgress(at: range.lowerBound), through: pathProgress(at: range.upperBound - 1))
  }
}
