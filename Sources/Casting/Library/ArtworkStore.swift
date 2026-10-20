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
/// 2. covers fetched for the album (Cover Art Archive), kept with the library
/// 3. our own disk cache of art extracted from files
/// 4. artwork embedded in the audio file (then written to our disk cache)
/// 5. a cover image next to the files (cover.jpg, folder.jpg, front.jpg, …)
final class ArtworkStore: @unchecked Sendable {
    static let shared = ArtworkStore()

    /// Posted on the main queue with the album's request ID as `object` when its cover changes.
    static let didChange = Notification.Name("ArtworkStore.didChange")

    private let diskCache: URL
    private let covers: URL
    private let memory = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// Requests already known to have no artwork, so scrolling doesn't retry them.
    private var misses = Set<String>()
    /// At most two audio files read for embedded art at once (they're usually on the network share).
    private let embeddedReads = AsyncLimiter(limit: 2)

    init(
        diskCache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("casting/Artwork"),
        covers: URL = LibraryStore.supportDirectory.appendingPathComponent("casting/Covers")
    ) {
        self.diskCache = diskCache
        self.covers = covers
        memory.totalCostLimit = 200 * 1024 * 1024
        try? FileManager.default.createDirectory(at: diskCache, withIntermediateDirectories: true)
    }

    /// Lets albums that had no art be looked up again (e.g. after the music share remounts).
    func forgetMisses() {
        lock.withLock { misses.removeAll() }
    }

    /// Uses `data` as the album's cover from now on (it outranks embedded art), and tells views
    /// showing the album to reload.
    func setCover(_ data: Data, for id: String) throws {
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try data.write(to: covers.appendingPathComponent(Self.fileName(for: id, extension: "img")), options: .atomic)
        try? FileManager.default.removeItem(at: diskCache.appendingPathComponent(Self.fileName(for: id)))
        lock.withLock { _ = misses.remove(id) }
        // NSCache can't list its keys, and covers are cheap to decode again.
        memory.removeAllObjects()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: id) }
    }

    /// The cover fetched for the album, if any (as stored, not resized).
    func fetchedCover(for id: String) -> Data? {
        try? Data(contentsOf: covers.appendingPathComponent(Self.fileName(for: id, extension: "img")))
    }

    /// Whether the album has art from any source (loads it, so it's cached for next time).
    func hasArtwork(_ request: ArtworkRequest) async -> Bool {
        await image(for: request, pixelSize: 64) != nil
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
        let fetched = covers.appendingPathComponent(Self.fileName(for: request.id, extension: "img"))
        if let image = Self.thumbnail(CGImageSourceCreateWithURL(fetched as CFURL, nil), maxPixels: pixelSize) {
            return image
        }
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

        for folder in Set(request.filePaths.prefix(3).map { ($0 as NSString).deletingLastPathComponent }).sorted() {
            guard !Task.isCancelled, let image = Self.folderImage(in: folder),
                  let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { continue }
            if let stored = Self.thumbnail(source, maxPixels: 512) {
                Self.writePNG(stored, to: cached)
            }
            return Self.thumbnail(source, maxPixels: pixelSize)
        }
        return nil
    }

    /// Names other players and rippers give a folder's cover, best first.
    static let folderImageNames = ["cover", "folder", "front", "albumart", "album"]

    /// A cover image in the folder (one directory listing, no file reads), if there is one.
    static func folderImage(in folder: String) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        var found: [String: String] = [:]
        for name in names where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["jpg", "jpeg", "png"].contains(ext) else { continue }
            let base = (name as NSString).deletingPathExtension.lowercased()
            if found[base] == nil { found[base] = name }
        }
        guard let name = folderImageNames.lazy.compactMap({ found[$0] }).first else { return nil }
        return URL(fileURLWithPath: folder).appendingPathComponent(name)
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

    private static func fileName(for id: String, extension ext: String = "png") -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + "." + ext
    }

    private static func memoryKey(_ request: ArtworkRequest, _ pixelSize: Int) -> NSString {
        "\(request.id)#\(pixelSize)" as NSString
    }
}
