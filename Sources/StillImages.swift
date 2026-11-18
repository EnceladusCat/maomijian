import Foundation
import ImageIO

enum StillImages {
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
}
