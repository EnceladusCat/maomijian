import AppKit
import ImageIO
import UniformTypeIdentifiers

enum EditorialCardImages {
  private static let photos: NSCache<NSData, CGImage> = {
    let cache = NSCache<NSData, CGImage>()
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()
  private static let symbols: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 64
    return cache
  }()

  static func prepare(_ url: URL) -> Data? {
    for limit in [640, 420] {
      guard let thumbnail = StillImages.image(url, limit: limit) else { return nil }
      let usesAlpha = [.first, .last, .premultipliedLast, .premultipliedFirst, .alphaOnly]
        .contains(thumbnail.alphaInfo)
      let type = usesAlpha ? UTType.png : UTType.jpeg
      let data = NSMutableData()
      guard let output = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
      CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary)
      if CGImageDestinationFinalize(output), data.length <= EditorialCard.maximumPictureBytes {
        return data as Data
      }
    }
    return nil
  }

  static func photo(_ data: Data) -> CGImage? {
    let key = data as NSData
    if let cached = photos.object(forKey: key) { return cached }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    photos.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    return image
  }

  static func symbol(_ name: String, tint: String) -> CGImage? {
    let key = "\(name)|\(tint)" as NSString
    if let cached = symbols.object(forKey: key) { return cached }
    let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: ink(tint)) ?? .white]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    symbols.setObject(image, forKey: key)
    return image
  }
}
