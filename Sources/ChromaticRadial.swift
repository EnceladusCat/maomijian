import CoreGraphics

enum ChromaticRadial {
  // Resample red and blue in opposite radial directions. The green channel and
  // the alpha at each original pixel provide the unshifted image and matte.
  static func shift(_ image: CGImage, amount: Double) -> CGImage {
    let width = image.width
    let height = image.height
    guard amount > 0,
      let source = bitmap(width, height), let target = bitmap(width, height),
      let src = source.data?.assumingMemoryBound(to: UInt8.self),
      let dst = target.data?.assumingMemoryBound(to: UInt8.self)
    else { return image }
    source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    source.flush()
    let red = 1 + 0.078 * amount
    let blue = 1 - 0.054 * amount
    func axis(_ count: Int, scale: Double) -> [Int] {
      let center = Double(count - 1) / 2
      return (0..<count).map { i in
        bound(Int((center + (Double(i) - center) / scale).rounded()), 0, count - 1)
      }
    }
    let reds = axis(width, scale: red).map { $0 * 4 }
    let blues = axis(width, scale: blue).map { $0 * 4 }
    let redRows = axis(height, scale: red)
    let blueRows = axis(height, scale: blue)
    func channel(_ input: UnsafePointer<UInt8>, _ index: Int, alpha: UInt8) -> UInt8 {
      let a = input[3]
      if a == alpha { return input[index] }
      return a == 0 ? 0 : UInt8(min(Int(alpha), Int(input[index]) * Int(alpha) / Int(a)))
    }
    for row in 0..<height {
      let r = src + redRows[row] * source.bytesPerRow
      let b = src + blueRows[row] * source.bytesPerRow
      let line = src + row * source.bytesPerRow
      let out = dst + row * target.bytesPerRow
      for x in 0..<width {
        let px = x * 4
        let alpha = line[px + 3]
        out[px] = channel(b + blues[x], 0, alpha: alpha)
        out[px + 1] = line[px + 1]
        out[px + 2] = channel(r + reds[x], 2, alpha: alpha)
        out[px + 3] = alpha
      }
    }
    return target.makeImage() ?? image
  }
}
