import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reading pictures from the vault, and preparing new ones to go into it.
public enum ImageFiles {
    public nonisolated static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]

    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    /// The picture at `url`, scaled down so neither side exceeds `maxPixels` (EXIF rotation applied).
    /// Cached by path, size and modification date, so an edited file is read again.
    public static func cgImage(at url: URL, maxPixels: Int = 2048) -> CGImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)|\(maxPixels)|\(stamp)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Width and height in pixels, as displayed (EXIF rotation applied).
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The longest side a picture keeps when it goes into the vault; bigger photos are scaled down
    /// so the git repository stays small.
    public static let maxStoredPixels = 2560

    /// Readies picked or pasted image data for the vault: PNG, JPEG and GIF stay as they are when small
    /// enough; photos (HEIC and friends) and very large pictures become JPEG at most 2560 px on a side.
    /// Returns the bytes and the file extension to use.
    public static func prepareForVault(_ data: Data, type: UTType?) -> (data: Data, ext: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let sourceType: UTType? = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? type
        let size = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).map {
            max($0[kCGImagePropertyPixelWidth] as? Int ?? 0, $0[kCGImagePropertyPixelHeight] as? Int ?? 0)
        } ?? 0
        let keep: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif")]
        if let (_, ext) = keep.first(where: { sourceType?.conforms(to: $0.0) == true }),
           size <= maxStoredPixels || ext == "gif" {
            return (data, ext)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(size, 1), maxStoredPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        // Screenshots and drawings (with transparency) stay PNG; photos become JPEG.
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let outType = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, outType.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, hasAlpha ? "png" : "jpg")
    }
}
