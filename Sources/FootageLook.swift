import Accelerate
import AppKit
import CoreImage
import CoreText

enum FootageLook {
  private static let context = CIContext(options: [.cacheIntermediates: false])
  private static let cpu = CIContext(options: [
    .cacheIntermediates: false, .useSoftwareRenderer: true,
  ])
  // In linear light, blurring white over a dark texture can look like a glow.
  private static let defocusContext = CIContext(options: [
    .cacheIntermediates: false, .workingColorSpace: rgb,
  ])
  private static let defocusBlend = CIColorKernel(source: """
    kernel vec4 blendDefocus(__sample sharp, __sample soft, vec2 inverseSize, vec2 radii, float strength) {
      float radius = length(destCoord() * inverseSize - vec2(0.5));
      float weight = strength * smoothstep(radii.x, radii.y, radius) * step(0.00001, soft.a);
      vec3 color = soft.rgb * sharp.a / max(soft.a, 0.00001);
      return vec4(mix(sharp.rgb, color, weight), sharp.a);
    }
    """)
  private static let clearRadius = 0.28
  private static let edgeRadius = 0.59
  private static let blurRadius = 0.019

  static func image(_ image: CGImage, look: FootageFilter, amount: Double) -> CGImage {
    guard amount > 0, look == .neon || look == .vhs || look == .edgeBlur else { return image }
    if look == .edgeBlur { return edgeBlur(image, amount: amount) }
    let source = CIImage(cgImage: image)
    let result: CIImage
    if look == .neon {
      let punch = source.applyingFilter(
        "CIColorControls",
        parameters: [
          kCIInputContrastKey: 1.65, kCIInputSaturationKey: 1.18,
        ])
      let neon = punch.applyingFilter(
        "CIFalseColor",
        parameters: [
          "inputColor0": CIColor(red: 0.18, green: 0.008, blue: 0.22),
          "inputColor1": CIColor(red: 0.30, green: 1, blue: 1),
        ])
      let glow = neon.clampedToExtent().applyingFilter(
        "CIBloom",
        parameters: [
          kCIInputRadiusKey: max(2, source.extent.height / 120), kCIInputIntensityKey: 0.48,
        ]
      ).cropped(to: source.extent)
      result = source.applyingFilter(
        "CIDissolveTransition",
        parameters: [
          kCIInputTargetImageKey: glow, kCIInputTimeKey: amount * 0.87,
        ])
    } else {
      result = source.applyingFilter(
        "CIColorControls",
        parameters: [
          kCIInputSaturationKey: 1 - amount * 0.32, kCIInputContrastKey: 1 - amount * 0.13,
          kCIInputBrightnessKey: amount * 0.045,
        ]
      ).applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1 - 0.08 * amount, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1 + 0.10 * amount, w: 0),
        ])
    }
    // A filtered transparent PNG must retain its matte.
    let matte = source.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      ])
    let output = result.applyingFilter(
      "CISourceAtopCompositing",
      parameters: [kCIInputBackgroundImageKey: matte])
    return context.createCGImage(output, from: source.extent)
      ?? cpu.createCGImage(output, from: source.extent)
      ?? softwareColor(image, look: look, amount: amount)
  }

  private static func stretchedBounds(_ bounds: CGRect, amount: Double) -> CGRect {
    let inset = -amount * 0.045 / 2
    return bounds.insetBy(dx: bounds.width * inset, dy: bounds.height * inset)
  }

  private static func edgeBlur(_ image: CGImage, amount: Double) -> CGImage {
    let source = CIImage(cgImage: image)
    let rect = source.extent
    let short = min(rect.width, rect.height)
    let scale = min(1, 720 / short)
    let stretched = stretchedBounds(rect, amount: amount)
    let restore = stretched.width / (rect.width * scale)
    let softened = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .clampedToExtent().applyingFilter(
        "CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, short * scale * blurRadius)])
      .transformed(by: CGAffineTransform(
        a: restore, b: 0, c: 0, d: restore, tx: stretched.minX, ty: stretched.minY))
      .cropped(to: rect)
    if let blended = defocusBlend?.apply(extent: rect, arguments: [
      source, softened, CIVector(x: 1 / rect.width, y: 1 / rect.height),
      CIVector(x: clearRadius, y: edgeRadius), amount,
    ]), let output = defocusContext.createCGImage(blended, from: rect, format: .RGBA8, colorSpace: rgb) {
      return output
    }
    return softwareEdgeBlur(image, amount: amount)
  }

  private static func softwareEdgeBlur(_ image: CGImage, amount: Double) -> CGImage {
    let scale = min(1, 720 / Double(min(image.width, image.height)))
    let w = max(1, Int((Double(image.width) * scale).rounded()))
    let h = max(1, Int((Double(image.height) * scale).rounded()))
    guard let small = bitmap(w, h), let soft = bitmap(w, h),
      let front = bitmap(image.width, image.height), let back = bitmap(image.width, image.height),
      let original = front.data?.assumingMemoryBound(to: UInt8.self),
      let blurred = back.data?.assumingMemoryBound(to: UInt8.self)
    else { return image }
    small.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var input = vImage_Buffer(
      data: small.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: small.bytesPerRow)
    var output = vImage_Buffer(
      data: soft.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: soft.bytesPerRow)
    // Match the approximate spread of the Gaussian with a single box convolution.
    let width = UInt32(max(3, Int(Double(min(w, h)) * blurRadius * sqrt(12)))) | 1
    guard vImageBoxConvolve_ARGB8888(
      &input, &output, nil, 0, 0, width, width, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError,
      let softened = soft.makeImage()
    else { return image }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    front.draw(image, in: bounds)
    back.draw(softened, in: stretchedBounds(bounds, amount: amount))
    let xSquared = (0..<image.width).map { pow((Double($0) + 0.5) / Double(image.width) - 0.5, 2) }
    let clearSquared = clearRadius * clearRadius
    for y in 0..<image.height {
      let dy = (Double(y) + 0.5) / Double(image.height) - 0.5
      let row = original.advanced(by: y * front.bytesPerRow)
      let softRow = blurred.advanced(by: y * back.bytesPerRow)
      for x in 0..<image.width {
        let radius2 = xSquared[x] + dy * dy
        let offset = x * 4
        let alpha = Int(row[offset + 3])
        let softAlpha = Int(softRow[offset + 3])
        guard radius2 > clearSquared, alpha > 0, softAlpha > 0 else { continue }
        let t = bound((sqrt(radius2) - clearRadius) / (edgeRadius - clearRadius), 0, 1)
        let weight = Int((256 * amount * t * t * (3 - 2 * t)).rounded())
        let sharpWeight = 256 - weight
        if alpha == softAlpha {
          for channel in offset..<offset + 3 {
            row[channel] = UInt8((Int(row[channel]) * sharpWeight + Int(softRow[channel]) * weight + 128) >> 8)
          }
        } else {
          for channel in offset..<offset + 3 {
            let color = Int(softRow[channel]) * alpha / softAlpha
            row[channel] = UInt8(bound((Int(row[channel]) * sharpWeight + color * weight + 128) >> 8, 0, alpha))
          }
        }
      }
    }
    return front.makeImage() ?? image
  }

  private static func softwareColor(_ src: CGImage, look: FootageFilter, amount: Double) -> CGImage
  {
    guard let g = bitmap(src.width, src.height),
      let pixels = g.data?.assumingMemoryBound(to: UInt8.self)
    else { return src }
    g.setBlendMode(.copy)
    g.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
    let amount256 = Int((amount * 224).rounded())
    let ramp: [(Int, Int, Int)] = (0...255).map { light in
      let low = bound(Double(light) / 116, 0, 1)
      let high = bound(Double(light - 116) / 139, 0, 1)
      return (
        Int(28 + 213 * low - 190 * high),
        Int(3 + 12 * low + 238 * high), Int(47 + 142 * low + 66 * high)
      )
    }
    for row in 0..<src.height {
      var pixel = pixels.advanced(by: row * g.bytesPerRow)
      for _ in 0..<src.width {
        let a = Int(pixel[3])
        if a > 0 {
          let b = Int(pixel[0])
          let green = Int(pixel[1])
          let r = Int(pixel[2])
          let light = (54 * r + 183 * green + 19 * b) >> 8
          if look == .neon {
            let (red, greenRamp, blue) = ramp[bound(light * 255 / a, 0, 255)]
            let original = 256 - amount256
            pixel[0] = UInt8(bound((b * original + blue * a * amount256 / 255) >> 8, 0, a))
            pixel[1] = UInt8(bound((green * original + greenRamp * a * amount256 / 255) >> 8, 0, a))
            pixel[2] = UInt8(bound((r * original + red * a * amount256 / 255) >> 8, 0, a))
          } else {
            pixel[0] = UInt8(bound(b + (light - b) * amount256 / 800 + amount256 * a / 4000, 0, a))
            pixel[1] = UInt8(bound(green + (light - green) * amount256 / 800, 0, a))
            pixel[2] = UInt8(bound(r + (light - r) * amount256 / 800, 0, a))
          }
        }
        pixel = pixel.advanced(by: 4)
      }
    }
    return g.makeImage() ?? src
  }

  static func drawOverlay(
    _ look: FootageFilter, amount: Double, in g: CGContext,
    rect: CGRect, frame: Int
  ) {
    guard amount > 0, !rect.isEmpty else { return }
    let u = min(rect.width, rect.height) / 540
    if look == .vhs {
      let spacing = max(2, 4 * u)
      g.setFillColor(ink("#181225", 0.26 * amount))
      let count = Int(rect.height / spacing)
      let phase = Double(frame % 4) * spacing / 4
      g.fill(
        (0..<count).map {
          CGRect(
            x: rect.minX, y: rect.minY + Double($0) * spacing + phase,
            width: rect.width, height: max(0.75, spacing * 0.24))
        })
      let drift = Double((frame * 17) % 241) / 241
      let band = CGRect(
        x: rect.minX, y: rect.minY + drift * rect.height,
        width: rect.width, height: max(1, u * 12))
      g.setFillColor(ink("#ECE5FC", 0.19 * amount))
      g.fill(band)
      return
    }
    guard look == .camera else { return }
    let inset = max(1, 23 * u)
    let corners = rect.insetBy(dx: inset, dy: inset)
    let length = min(corners.width, corners.height) * 0.095
    g.setStrokeColor(ink("#FFFFFF", 0.85 * amount))
    g.setLineWidth(max(1, 2 * u))
    for sx in [-1.0, 1.0] {
      for sy in [-1.0, 1.0] {
        let x = corners.midX + corners.width / 2 * sx
        let y = corners.midY + corners.height / 2 * sy
        g.move(to: CGPoint(x: x - sx * length, y: y))
        g.addLine(to: CGPoint(x: x, y: y))
        g.addLine(to: CGPoint(x: x, y: y - sy * length))
      }
    }
    g.strokePath()
    let cross: CGFloat = 13 * u
    g.move(to: CGPoint(x: rect.midX - cross, y: rect.midY))
    g.addLine(to: CGPoint(x: rect.midX + cross, y: rect.midY))
    g.move(to: CGPoint(x: rect.midX, y: rect.midY - cross))
    g.addLine(to: CGPoint(x: rect.midX, y: rect.midY + cross))
    g.strokePath()
    let labelY = corners.minY + max(7, 22 * u)
    let diameter = max(3, 11 * u)
    g.setFillColor(ink("#F36877", (frame / 15 % 2 == 0 ? 1 : 0.45) * amount))
    g.fillEllipse(
      in: CGRect(x: corners.minX + inset, y: labelY - diameter, width: diameter, height: diameter))
    cameraLabel(
      "REC", at: CGPoint(x: corners.minX + inset + 1.6 * diameter, y: labelY),
      size: max(5, 19 * u), alpha: amount, in: g)
    cameraLabel(
      tc(frame), at: CGPoint(x: corners.minX + inset, y: corners.maxY - inset / 2),
      size: max(5, 17 * u), alpha: amount, in: g)
  }

  private static func cameraLabel(
    _ label: String, at origin: CGPoint, size: CGFloat, alpha: Double,
    in g: CGContext
  ) {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: label,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
          .foregroundColor: NSColor(cgColor: ink("#FFFFFF", alpha)) ?? .white,
        ]))
    g.saveGState()
    g.translateBy(x: origin.x, y: origin.y)
    g.scaleBy(x: 1, y: -1)
    g.textMatrix = .identity
    g.textPosition = .zero
    CTLineDraw(line, g)
    g.restoreGState()
  }
}
