import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageResizer {
    struct Probe {
        var size: CGSize
        var type: String
        var hasAlpha: Bool
    }

    static let lossy: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier,
                                     "org.webmproject.webp"]

    static func probe(_ url: URL) -> Probe? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return Probe(size: size, type: type, hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }

    static func ext(for type: String, source: URL) -> String {
        if let t = UTType(type), let srcType = UTType(filenameExtension: source.pathExtension), t == srcType {
            let e = source.pathExtension.lowercased()
            return e == "jpeg" ? "jpg" : e
        }
        if type == UTType.jpeg.identifier { return "jpg" }
        return UTType(type)?.preferredFilenameExtension ?? "png"
    }

    static func outputType(sourceType: String?, hasAlpha: Bool, web: Bool) -> String {
        let jpeg = UTType.jpeg.identifier, png = UTType.png.identifier
        if web {
            if sourceType == jpeg || sourceType == png { return sourceType! }
            return hasAlpha ? png : jpeg
        }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if let t = sourceType, writable.contains(t), t != UTType.gif.identifier { return t }
        return png
    }

    static func makeImage(_ url: URL, width: Int?, height: Int?, fit: FitMode, padWhite: Bool) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = probe(url)?.size
        else { throw CrateError("Can't read image") }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(full.width, full.height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { throw CrateError("Can't decode image") }
        guard let width, let height else { return image }

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = image.bitsPerComponent > 8
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CrateError("Can't allocate canvas") }

        ctx.interpolationQuality = .high
        if !hasAlpha {
            ctx.setFillColor(CGColor(gray: padWhite ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let sx = CGFloat(width) / iw, sy = CGFloat(height) / ih
        let scale = fit == .fill ? max(sx, sy) : min(sx, sy)
        let dw = iw * scale, dh = ih * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2,
                                   width: dw, height: dh))
        guard let out = ctx.makeImage() else { throw CrateError("Can't render image") }
        return out
    }

    static func write(_ image: CGImage, to dst: URL, type: String, quality: Double = 0.95) throws {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type as CFString, 1, nil)
        else { throw CrateError("Can't create output") }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: 72,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CrateError("Can't write image") }
    }

    /// Returns a warning when the file can't be brought under the cap.
    static func render(_ url: URL, to dst: URL, type: String, width: Int?, height: Int?,
                       fit: FitMode, padWhite: Bool, capBytes: Int?) throws -> String? {
        let image = try makeImage(url, width: width, height: height, fit: fit, padWhite: padWhite)
        try write(image, to: dst, type: type)
        guard let capBytes, fileSize(dst) > capBytes else { return nil }
        guard lossy.contains(type) else { return "Over size cap (\(mb(fileSize(dst)))) — format is lossless" }
        var quality = 0.9
        while quality >= 0.45 {
            try write(image, to: dst, type: type, quality: quality)
            if fileSize(dst) <= capBytes { return nil }
            quality -= 0.05
        }
        return "Still over size cap at 45% quality (\(mb(fileSize(dst))))"
    }

    /// Rewrites the container without recompressing. Orientation and colour profile survive.
    static func stripMetadata(_ url: URL, to dst: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, CGImageSourceGetCount(src), nil)
        else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        // ImageIO rejects kCGImageDestinationOrientation alongside kCGImageDestinationMetadata.
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        return CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil)
    }

    static func fileSize(_ url: URL) -> Int {
        // Not URL.resourceValues: it caches, and outputs are rewritten in place.
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
