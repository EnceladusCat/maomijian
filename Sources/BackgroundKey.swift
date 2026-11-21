import CoreImage
import simd

enum BackgroundKey {
  private typealias Tone = SIMD3<Float>
  private static let weights = Tone(0.30, 0.45, 0.25)
  private static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: rgb])
  private static let kernel = CIColorKernel(source: """
    kernel vec4 keyBackground(__sample image, vec3 key, vec3 weights, float inner, float outer, float strength) {
      vec3 difference = unpremultiply(image).rgb - key;
      float distance = sqrt(dot(difference * difference, weights));
      float coverage = mix(1.0, smoothstep(inner, outer, distance), strength);
      return image * coverage;
    }
    """)

  static let defaultSensitivity = 0.40

  static func image(_ source: CGImage, sensitivity: Double, strength: Double, color: UInt32? = nil) -> CGImage {
    guard strength > 0, let key = color.map(tone) ?? edgeColor(in: source) else { return source }
    let outer = Float(0.055 + 0.30 * sensitivity)
    let inner = outer * 0.68
    let input = CIImage(cgImage: source)
    if let keyed = kernel?.apply(extent: input.extent, arguments: [
      input, CIVector(x: CGFloat(key.x), y: CGFloat(key.y), z: CGFloat(key.z)),
      CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z)),
      inner, outer, strength,
    ]), let result = context.createCGImage(keyed, from: input.extent, format: .RGBA8, colorSpace: rgb) {
      return result
    }
    return softwareKey(source, key: key, inner: inner, outer: outer, strength: Float(strength))
  }

  static func hex(_ color: UInt32) -> String { String(format: "#%06X", color) }

  static func sample(_ image: CGImage, at point: CGPoint) -> UInt32? {
    guard (0..<1).contains(point.x), (0..<1).contains(point.y),
      let pixel = image.cropping(to: CGRect(x: Int(point.x * CGFloat(image.width)),
                                            y: Int(point.y * CGFloat(image.height)), width: 1, height: 1)),
      let context = bitmap(1, 1), let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let alpha = Int(bytes[3])
    guard alpha >= 128 else { return nil }
    func component(_ index: Int) -> UInt32 { UInt32(min(255, (Int(bytes[index]) * 255 + alpha / 2) / alpha)) }
    return (component(2) << 16) | (component(1) << 8) | component(0)
  }

  private static func tone(_ color: UInt32) -> Tone {
    Tone(Float((color >> 16) & 255), Float((color >> 8) & 255), Float(color & 255)) / 255
  }

  private static func edgeColor(in source: CGImage) -> Tone? {
    let side = 48
    guard let proxy = bitmap(side, side), let data = proxy.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    proxy.interpolationQuality = .low
    proxy.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

    let perSide = 28
    let total = 4 * perSide
    var samples = [(color: Tone, edge: Int)]()
    samples.reserveCapacity(total)
    for edge in 0..<4 {
      for inset in [2, 5] {
        for i in stride(from: 4, to: side - 3, by: 3) {
          let coordinates = [(i, inset), (i, side - 1 - inset), (inset, i), (side - 1 - inset, i)][edge]
          let pixel = data.advanced(by: coordinates.1 * proxy.bytesPerRow + coordinates.0 * 4)
          guard pixel[3] >= 250 else { continue }
          samples.append((Tone(Float(pixel[2]), Float(pixel[1]), Float(pixel[0])) / Float(pixel[3]), edge))
        }
      }
    }
    // Require a common color around the source margin before cutting any pixels.
    var best = 0
    var result: Tone?
    for i in stride(from: 0, to: samples.count, by: 3) {
      let seed = samples[i].color
      var count = 0
      var edges = SIMD4<Int32>.zero
      var sum = Tone.zero
      for sample in samples where distanceSquared(sample.color, seed) <= 0.105 * 0.105 {
        count += 1
        edges[sample.edge] += 1
        sum += sample.color
      }
      let consistentEdges = (0..<4).filter { edges[$0] >= perSide / 2 }.count
      if count > best && count >= total * 3 / 5 && consistentEdges >= 3 {
        best = count
        result = sum / Float(count)
      }
    }
    return result
  }

  private static func distanceSquared(_ a: Tone, _ b: Tone) -> Float {
    let delta = a - b
    return simd_dot(delta * delta, weights)
  }

  private static func softwareKey(_ source: CGImage, key: Tone, inner: Float, outer: Float, strength: Float) -> CGImage {
    guard let target = bitmap(source.width, source.height),
      let bytes = target.data?.assumingMemoryBound(to: UInt8.self)
    else { return source }
    target.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    let inner2 = inner * inner
    let outer2 = outer * outer
    for y in 0..<source.height {
      var pixel = bytes.advanced(by: y * target.bytesPerRow)
      for _ in 0..<source.width {
        let alpha = Float(pixel[3])
        if alpha > 0 {
          let tone = Tone(Float(pixel[2]), Float(pixel[1]), Float(pixel[0])) / alpha
          let distance2 = distanceSquared(tone, key)
          if distance2 < outer2 {
            let t = distance2 <= inner2 ? 0 : (sqrt(distance2) - inner) / (outer - inner)
            let coverage = 1 - strength * (1 - t * t * (3 - 2 * t))
            for channel in 0..<4 { pixel[channel] = UInt8((Float(pixel[channel]) * coverage).rounded()) }
          }
        }
        pixel = pixel.advanced(by: 4)
      }
    }
    return target.makeImage() ?? source
  }
}
