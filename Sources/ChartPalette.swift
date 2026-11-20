import CoreGraphics

struct ChartPalette {
  let colors: [CGColor]
  let slots: [Int]

  init(_ points: [ChartPoint], mode: ChartColorMode, high: String, low: String) {
    switch mode {
    case .automatic, .single:
      colors = [ink(high)]
      slots = Array(repeating: 0, count: points.count)
    case .category:
      colors = [high, "#AAA7FF", "#FFBA7F", "#79BCFA", "#F28EA8", "#F4DA7A", "#80D8E7", "#C7DE91"]
        .map { ink($0) }
      let count = colors.count
      slots = points.indices.map { $0 % count }
    case .sign:
      colors = [ink(high), ink(low)]
      slots = points.map { $0.y < 0 ? 1 : 0 }
    case .rank, .magnitude:
      let steps = 32
      let start = ink(low).components ?? [0, 0, 0, 1]
      let end = ink(high).components ?? [1, 1, 1, 1]
      colors = (0...steps).map { i in
        let t = Double(i) / Double(steps)
        let rgb = zip(start, end).map { $0 * (1 - t) + $1 * t }
        return CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
      }
      let scores: [Double]
      if mode == .rank {
        let values = Set(points.map(\.y)).sorted()
        let scale = Double(max(1, values.count - 1))
        let ranks = Dictionary(uniqueKeysWithValues: values.enumerated().map {
          ($0.element, values.count == 1 ? 1.0 : Double($0.offset) / scale)
        })
        scores = points.map { ranks[$0.y] ?? 0 }
      } else {
        let largest = points.lazy.map { abs($0.y) }.max() ?? 0
        scores = points.map { largest > 0 ? abs($0.y) / largest : 0 }
      }
      slots = scores.map { Int(($0 * Double(steps)).rounded()) }
    }
  }
}
