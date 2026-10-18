import AVFoundation
import Foundation

/// Writes tags into one audio file without ever leaving it half-written:
///
/// 1. Read the file and note its size and modification date.
/// 2. Build the new file in memory and check it (tags parse and hold the new values, everything
///    else is byte-identical).
/// 3. Write it to a hidden temp file next to the original, read that back from disk, and check it
///    again; MP3/M4A copies must also open in AVFoundation with the original's duration.
/// 4. If the original's size or modification date changed meanwhile, give up.
/// 5. Copy the original's permissions, creation date and extended attributes (Finder tags) onto
///    the temp file and rename it over the original, which is atomic.
///
/// Any failure deletes the temp file and leaves the original untouched. Blocking I/O: call off
/// the main thread.
///
/// Fast path: when the new tags fit in the space the old ones take up (MP3 and FLAC tags are at
/// the start of the file and usually have padding), only the tag bytes are read and only the bytes
/// that changed are written back in place, then read back and compared. Over a slow share that's a
/// few KB instead of the whole file several times over. The audio is never written to; if the
/// patched bytes don't read back as written, the old bytes are put back.
enum TagFileWriter {
    enum Outcome: Equatable {
        case written(fileSize: Int64)
        /// The file already held these values.
        case unchanged
    }

    /// `beforeReplace` runs after verification, just before the final modification-date check
    /// (tests use it to simulate another app touching the file).
    static func write(_ values: TagValues, to url: URL, beforeReplace: (() throws -> Void)? = nil) async throws -> Outcome {
        guard let before = stamp(url) else { throw TagWriteError.fileMissing }
        if let outcome = try patchInPlace(values, url: url, before: before, beforeReplace: beforeReplace) {
            return outcome
        }
        let data = try Data(contentsOf: url)
        guard data.count == before.size, stamp(url) == before else { throw TagWriteError.modifiedSinceRead }
        let original = [UInt8](data)
        let format = try TagFormats.handler(for: url, bytes: original)

        let rewritten = try format.rewrite(original, with: values)
        if rewritten == original { return .unchanged }
        try format.verify(original: original, rewritten: rewritten, values: values)

        let temp = tempURL(for: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        try writeSynced(rewritten, to: temp)

        // Check what actually landed on disk, not what we meant to write.
        let readBack = [UInt8](try Data(contentsOf: temp))
        guard readBack == rewritten else { throw TagWriteError.verificationFailed("the copy on disk differs") }
        try format.verify(original: original, rewritten: readBack, values: values)
        if !(format is FLACTag.Type) {  // AVFoundation reads whole FLAC files over the network; skip.
            try await checkPlayable(temp, against: url)
        }

        try beforeReplace?()
        guard stamp(url) == before else { throw TagWriteError.modifiedSinceRead }
        copyMetadata(from: url, to: temp)
        guard rename(temp.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't replace the file: \(String(cString: strerror(errno)))",
            ])
        }
        return .written(fileSize: Int64(rewritten.count))
    }

    /// The fast path (see above). nil: the tags don't fit or the format can't be patched; do the
    /// full rewrite.
    private static func patchInPlace(_ values: TagValues, url: URL, before: Stamp,
                                     beforeReplace: (() throws -> Void)?) throws -> Outcome? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var head = [UInt8](try handle.read(upToCount: min(before.size, 256 * 1024)) ?? Data())
        guard let format = try? TagFormats.handler(for: url, bytes: head) else { return nil }
        var region = format.tagRegion(in: head)
        while region == .needMore, head.count < before.size {
            // FLAC metadata blocks (artwork) can run past the first read.
            head += [UInt8](try handle.read(upToCount: min(head.count * 4, before.size - head.count)) ?? Data())
            region = format.tagRegion(in: head)
        }
        guard case .length(let length) = region, length > 0, length < before.size else { return nil }
        if head.count < length {
            head += [UInt8](try handle.read(upToCount: length - head.count) ?? Data())
            guard head.count == length else { return nil }
        } else {
            head.removeLast(head.count - length)
        }
        guard stamp(url) == before else { throw TagWriteError.modifiedSinceRead }

        let rewritten = try format.rewrite(head, with: values)
        if rewritten == head { return .unchanged }
        guard rewritten.count == head.count else { return nil }
        try format.verify(original: head, rewritten: rewritten, values: values)

        let first = rewritten.indices.first { rewritten[$0] != head[$0] }!
        let last = rewritten.indices.last { rewritten[$0] != head[$0] }!
        let patch = Array(rewritten[first...last]), old = Array(head[first...last])

        try beforeReplace?()
        guard stamp(url) == before else { throw TagWriteError.modifiedSinceRead }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw posixError("Couldn't open the file for writing") }
        defer { close(fd) }
        func put(_ bytes: [UInt8]) throws {
            let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, off_t(first)) }
            guard n == bytes.count, fsync(fd) == 0 else { throw posixError("Couldn't write the tags") }
        }
        func onDisk() -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: patch.count)
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, patch.count, off_t(first)) }
            return n == patch.count ? buffer : []
        }
        try put(patch)
        guard onDisk() == patch, stamp(url)?.size == before.size else {
            try? put(old)
            throw TagWriteError.verificationFailed("the tags on disk differ; the old ones were put back")
        }
        return .written(fileSize: Int64(before.size))
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))",
        ])
    }

    struct Stamp: Equatable {
        var size: Int
        var modified: timespec

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(size: Int(info.st_size), modified: info.st_mtimespec)
    }

    /// Hidden (so folder scans skip it) and keeping the extension (so AVFoundation can open it).
    static func tempURL(for url: URL) -> URL {
        let id = UUID().uuidString.prefix(8)
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).casting-\(id).\(url.pathExtension)")
    }

    private static func writeSynced(_ bytes: [UInt8], to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    private static func checkPlayable(_ copy: URL, against original: URL) async throws {
        async let originalDuration = try? AVURLAsset(url: original).load(.duration).seconds
        async let copyDuration = try? AVURLAsset(url: copy).load(.duration).seconds
        let (a, b) = await (originalDuration, copyDuration)
        guard let a, a.isFinite, a > 0 else { return }  // AVFoundation can't read the original either
        guard let b, b.isFinite, abs(a - b) < 0.05 else {
            throw TagWriteError.verificationFailed("AVFoundation reads a different duration")
        }
    }

    private static func copyMetadata(from original: URL, to copy: URL) {
        // Best effort: network shares may refuse some of these, and the tags matter more.
        mirrorExtendedAttributes(from: original.path, to: copy.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: original.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        keep[.posixPermissions] = attributes[.posixPermissions]
        keep[.creationDate] = attributes[.creationDate]
        try? FileManager.default.setAttributes(keep, ofItemAtPath: copy.path)
    }

    /// Gives the copy exactly the original's extended attributes, one at a time so one refusal
    /// doesn't skip the rest. Not copyfile(COPYFILE_XATTR): with the source on a share mounted
    /// with `quarantine` (as SMB shares are), it stamps com.apple.quarantine on the copy, and it
    /// stops at the first attribute the system won't let it write (com.apple.provenance).
    static func mirrorExtendedAttributes(from original: String, to copy: String) {
        let wanted = extendedAttributeNames(original)
        for name in extendedAttributeNames(copy) where !wanted.contains(name) {
            removexattr(copy, name, XATTR_NOFOLLOW)
        }
        for name in wanted {
            let size = getxattr(original, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: size)
            guard getxattr(original, name, &value, size, 0, XATTR_NOFOLLOW) == size else { continue }
            setxattr(copy, name, value, size, 0, XATTR_NOFOLLOW)
        }
    }

    static func extendedAttributeNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
