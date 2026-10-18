import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// What to look up artwork for: an album, or the album a track belongs to.
struct ArtworkRequest: Hashable, Sendable {
    /// Cache identity, shared by every track of the same album.
    let id: String
    /// Audio files to read embedded artwork from.
    let filePaths: [String]
}

/// A counting semaphore for async code.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Loads album artwork, cheapest source first:
/// 1. memory cache
/// 2. our own disk cache of art extracted from files
/// 3. artwork embedded in the audio file (then written to our disk cache)
final class ArtworkStore: @unchecked Sendable {
    static let shared = ArtworkStore()

    private let diskCache: URL
    private let memory = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// Requests already known to have no artwork, so scrolling doesn't retry them.
    private var misses = Set<String>()
    /// At most two audio files read for embedded art at once (they're usually on the network share).
    private let embeddedReads = AsyncLimiter(limit: 2)

    init(
        diskCache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("casting/Artwork")
    ) {
        self.diskCache = diskCache
        memory.totalCostLimit = 200 * 1024 * 1024
        try? FileManager.default.createDirectory(at: diskCache, withIntermediateDirectories: true)
    }

    /// Lets albums that had no art be looked up again (e.g. after the music share remounts).
    func forgetMisses() {
        lock.withLock { misses.removeAll() }
    }

    /// Synchronous memory-cache hit, so already-seen covers appear without a flash.
    func cachedImage(for request: ArtworkRequest, pixelSize: Int) -> NSImage? {
        memory.object(forKey: Self.memoryKey(request, pixelSize))
    }

    func image(for request: ArtworkRequest, pixelSize: Int) async -> NSImage? {
        let key = Self.memoryKey(request, pixelSize)
        if let hit = memory.object(forKey: key) { return hit }
        if lock.withLock({ misses.contains(request.id) }) { return nil }

        // Detached so decoding stays off the main actor; cancellation is forwarded so covers that
        // scroll out of view stop loading instead of competing with playback for the network.
        let task = Task.detached(priority: .userInitiated) { [self] in
            await load(request, pixelSize: pixelSize)
        }
        let loaded = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }

        guard let loaded else {
            // A cancelled load proves nothing about whether the album has art.
            if !task.isCancelled { lock.withLock { _ = misses.insert(request.id) } }
            return nil
        }
        let image = NSImage(cgImage: loaded, size: .zero)
        memory.setObject(image, forKey: key, cost: loaded.width * loaded.height * 4)
        return image
    }

    // MARK: Loading

    private func load(_ request: ArtworkRequest, pixelSize: Int) async -> CGImage? {
        let cached = diskCache.appendingPathComponent(Self.fileName(for: request.id))
        if let image = Self.thumbnail(CGImageSourceCreateWithURL(cached as CFURL, nil), maxPixels: pixelSize) {
            return image
        }

        for path in request.filePaths.prefix(3) {
            guard !Task.isCancelled else { return nil }
            await embeddedReads.wait()
            let data = Task.isCancelled ? nil : await Self.embeddedArtwork(at: URL(fileURLWithPath: path))
            await embeddedReads.signal()
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            // Keep a 512 px copy on disk so the file isn't re-read next launch.
            if let stored = Self.thumbnail(source, maxPixels: 512) {
                Self.writePNG(stored, to: cached)
            }
            return Self.thumbnail(source, maxPixels: pixelSize)
        }
        return nil
    }

    /// Album identity: artist + album, ignoring case, stray whitespace and Unicode normalization.
    static func indexKey(artist: String, album: String) -> String {
        func normalize(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                // "/" can't appear in a folder name; Finder shows ":" stored as "/" and vice versa.
                .replacingOccurrences(of: "/", with: ":")
        }
        return normalize(artist) + "\u{1}" + normalize(album)
    }

    private static func embeddedArtwork(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        for item in artwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource?, maxPixels: Int) -> CGImage? {
        guard let source, CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func fileName(for id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private static func memoryKey(_ request: ArtworkRequest, _ pixelSize: Int) -> NSString {
        "\(request.id)#\(pixelSize)" as NSString
    }
}
