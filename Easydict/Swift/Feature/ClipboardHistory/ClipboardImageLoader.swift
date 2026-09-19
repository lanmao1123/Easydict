//
//  ClipboardImageLoader.swift
//  Easydict
//
//  Created by lanmao1123 on 2026/9/19.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import ImageIO

// MARK: - ClipboardImageLoader

/// Loads clipboard images at display size and bounds their decoded memory in
/// an NSCache. Original PNG payloads stay on disk for copying; UI previews use
/// smaller bitmap representations decoded off the main thread.
///
/// NSCache and OperationQueue synchronize their own mutable state, so the
/// shared loader is safe to cross concurrency domains.
final class ClipboardImageLoader: @unchecked Sendable {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = ClipboardImageLoader()

    /// Loads an image whose decoded long edge is no larger than `maxPixel`.
    /// `cacheIdentity` must change when the URL is replaced by another file.
    func image(
        at url: URL,
        cacheIdentity: String,
        maxPixel: Int
    ) async
        -> NSImage? {
        let key = Self.cacheKey(cacheIdentity: cacheIdentity, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            decodeQueue.addOperation {
                let image = Self.downsampledImage(at: url, maxPixel: maxPixel)
                if let image {
                    let cost = Self.memoryCost(of: image)
                    self.cache.setObject(image, forKey: key as NSString, cost: cost)
                }
                continuation.resume(returning: image)
            }
        }
    }

    /// Drops cached representations when an entry's image files are deleted.
    func removeImages(fileNames: [String?]) {
        for name in fileNames.compactMap(\.self) {
            for maxPixel in Self.knownPixelSizes {
                cache.removeObject(
                    forKey: Self.cacheKey(cacheIdentity: name, maxPixel: maxPixel) as NSString
                )
            }
        }
    }

    /// Drops all clipboard image bitmaps, including entries cleared in bulk.
    func clear() {
        cache.removeAllObjects()
    }

    // MARK: Private

    private static let knownPixelSizes = [thumbnailPixelSize, previewPixelSize]
    private static let thumbnailPixelSize = 160
    private static let previewPixelSize = 1_600

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.evictsObjectsWithDiscardedContent = false
        return cache
    }()

    /// Two concurrent decoders keep scrolling responsive without allowing a
    /// long image backlog to spike CPU, memory or battery usage.
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private static func cacheKey(cacheIdentity: String, maxPixel: Int) -> String {
        "\(cacheIdentity)#\(maxPixel)"
    }

    private static func downsampledImage(at url: URL, maxPixel: Int) -> NSImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }

            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as [CFString: Any] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private static func memoryCost(of image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 1
        }
        return cgImage.bytesPerRow * cgImage.height
    }
}
