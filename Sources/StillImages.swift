import Foundation
import ImageIO
import UniformTypeIdentifiers

enum StillImages {
  static let previewLimit = 2160
  static let thumbnailLimit = 140
  private static let cache: NSCache<NSString, CGImage> = {
    let images = NSCache<NSString, CGImage>()
    images.totalCostLimit = 96 * 1024 * 1024
    return images
  }()
  private static func source(_ url: URL) -> CGImageSource? {
    CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
  }
  static func dimensions(_ url: URL) -> CGSize? {
    guard let source = source(url),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let w = properties[kCGImagePropertyPixelWidth] as? Int,
      let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
  }
  static func image(_ url: URL, limit: Int) -> CGImage? {
    let file = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let stamp = file?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
    let key = (url.absoluteString + "|\(stamp)|\(file?.fileSize ?? 0)|\(limit)") as NSString
    if let hit = cache.object(forKey: key) { return hit }
    guard let source = source(url) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: limit,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    return image
  }

  static func thumbnail(from image: CGImage) -> CGImage? {
    let longest = max(image.width, image.height)
    guard longest > thumbnailLimit else { return image }
    let scale = Double(thumbnailLimit) / Double(longest)
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let context = bitmap(width, height) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  static func writePNG(_ image: CGImage, to url: URL) throws {
    guard let encoder = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw EditError.message(L("无法写入 PNG 图片。")) }
    CGImageDestinationAddImage(encoder, image, nil)
    guard CGImageDestinationFinalize(encoder) else {
      throw EditError.message(L("无法写入 PNG 图片。"))
    }
  }
}
