import Foundation

/// One shared file: where it really lives, and what we advertise about it.
struct SlskSharedFile: Sendable {
    /// Path other users see, backslash-separated: `Music\Artist\Album\01 Song.flac`.
    let virtualPath: String
    let url: URL
    let size: UInt64
    var bitrate: Int?
    var durationSeconds: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var isVBR: Bool

    /// Lowercased virtual path, what queries match against.
    let searchText: String

    /// The last path component: `01 Song.flac`.
    var fileName: String {
        virtualPath.split(separator: "\\").last.map(String.init) ?? virtualPath
    }

    var isLossless: Bool {
        ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"].contains((virtualPath as NSString).pathExtension.lowercased())
    }
}

/// Everything known about a shared file before looking at the file's audio itself.
struct SlskFileAttributes: Sendable {
    var bitrate: Int?
    var durationSeconds: Int?
    var sampleRate: Int?
    var bitDepth: Int?
}

/// An immutable scan of the shared folder: what searches match against, what browsing
/// returns, and how queued upload paths map back to real files.
struct SlskShareSnapshot: Sendable {
    let files: [SlskSharedFile]
    let filesByVirtualPath: [String: SlskSharedFile]
    let folderCount: Int
    /// Prebuilt zlib payload of the `SharedFileListResponse` (peer code 5).
    let browsePayload: Data

    static let empty = SlskShareSnapshot(files: [], filesByVirtualPath: [:], folderCount: 0, browsePayload: (try? SlskZlib.deflate({
        var writer = SlskWriter()
        writer.u32(0)  // no folders
        writer.u32(0)  // unknown, always 0
        return writer.data
    }())) ?? Data())

    var isEmpty: Bool { files.isEmpty }

    /// All-words-match search, Soulseek style: every term must appear in the file's virtual
    /// path; terms starting with "-" must not. Case-insensitive.
    func matches(query: String, limit: Int) -> [SlskSharedFile] {
        var include: [String] = []
        var exclude: [String] = []
        for word in query.lowercased().split(separator: " ") {
            if word.hasPrefix("-"), word.count > 1 {
                exclude.append(String(word.dropFirst()))
            } else if word != "-" {
                include.append(String(word))
            }
        }
        // A bare or too-vague query would match the whole share; don't answer those.
        guard !include.isEmpty, include.joined().count >= 3 else { return [] }

        var found: [SlskSharedFile] = []
        for file in files {
            guard include.allSatisfy({ file.searchText.contains($0) }),
                  !exclude.contains(where: { file.searchText.contains($0) }) else { continue }
            found.append(file)
            if found.count >= limit { break }
        }
        return found
    }
}

/// Builds a `SlskShareSnapshot` from a folder on disk.
enum SlskShareScanner {
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "mp4", "aac", "ogg", "opus", "wav", "aiff", "aif",
        "alac", "ape", "wv", "mpc", "wma",
    ]
    private static let maxFiles = 200_000

    /// Walks `folder` and returns the snapshot. Slow on big or networked folders — call it
    /// off the main thread. `attributes` supplies audio details for files it knows (susurrus's
    /// own library); unknown files are shared with size only.
    static func scan(folder: URL, attributes: (String) -> SlskFileAttributes?) -> SlskShareSnapshot {
        let rootName = sanitizeComponent(folder.lastPathComponent)
        let rootPath = folder.standardizedFileURL.path

        var filesByFolder: [String: [SlskSharedFile]] = [:]
        var folderOrder: [String] = []
        var count = 0

        let enumerator = FileManager.default.enumerator(
            at: folder.standardizedFileURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard count < maxFiles else { break }
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }

            let standardized = url.standardizedFileURL
            var relative = standardized.path
            if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
            let components = relative.split(separator: "/").map { sanitizeComponent(String($0)) }
            guard !components.isEmpty else { continue }
            let virtualPath = ([rootName] + components).joined(separator: "\\")
            let virtualFolder = ([rootName] + components.dropLast()).joined(separator: "\\")

            let known = attributes(standardized.path)
            let file = SlskSharedFile(
                virtualPath: virtualPath,
                url: standardized,
                size: UInt64(size),
                bitrate: known?.bitrate,
                durationSeconds: known?.durationSeconds,
                sampleRate: known?.sampleRate,
                bitDepth: known?.bitDepth,
                isVBR: false,
                searchText: virtualPath.lowercased()
            )
            if filesByFolder[virtualFolder] == nil { folderOrder.append(virtualFolder) }
            filesByFolder[virtualFolder, default: []].append(file)
            count += 1
        }

        let ordered = folderOrder.flatMap { filesByFolder[$0] ?? [] }
        return SlskShareSnapshot(
            files: ordered,
            filesByVirtualPath: Dictionary(ordered.map { ($0.virtualPath, $0) }) { first, _ in first },
            folderCount: folderOrder.count,
            browsePayload: browsePayload(folderOrder: folderOrder, filesByFolder: filesByFolder)
        )
    }

    /// Remote-facing path pieces can't contain the separator; also keep them non-empty.
    private static func sanitizeComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "-")
        return cleaned.isEmpty ? "folder" : cleaned
    }

    /// `SharedFileListResponse` payload: zlib(u32 nfolders, per folder: string path +
    /// u32 nfiles + file infos, then u32 unknown = 0). Built once per scan. File infos here carry
    /// the bare file name (the folder path is sent once above them), as other clients send and
    /// expect; search responses carry the full path.
    private static func browsePayload(folderOrder: [String], filesByFolder: [String: [SlskSharedFile]]) -> Data {
        var writer = SlskWriter()
        writer.u32(UInt32(folderOrder.count))
        for folder in folderOrder {
            writer.string(folder)
            let files = filesByFolder[folder] ?? []
            writer.u32(UInt32(files.count))
            for file in files {
                writer.fileInfo(file, name: file.fileName)
            }
        }
        writer.u32(0)  // unknown, official clients send 0
        return (try? SlskZlib.deflate(writer.data)) ?? SlskShareSnapshot.empty.browsePayload
    }
}

extension SlskWriter {
    /// The file-info record used by search responses and share lists: code byte, name (the full
    /// virtual path unless `name` is given), size, empty extension (as modern clients send), and
    /// the quality attributes we know.
    /// Attribute codes: 0 bitrate, 1 duration, 2 VBR, 4 sample rate, 5 bit depth.
    mutating func fileInfo(_ file: SlskSharedFile, name: String? = nil) {
        u8(1)
        string(name ?? file.virtualPath)
        u64(file.size)
        u32(0)  // empty extension string

        var attributes: [(UInt32, UInt32)] = []
        if file.isLossless {
            if let duration = file.durationSeconds { attributes.append((1, UInt32(max(0, duration)))) }
            if let rate = file.sampleRate { attributes.append((4, UInt32(max(0, rate)))) }
            if let depth = file.bitDepth { attributes.append((5, UInt32(max(0, depth)))) }
        } else {
            if let bitrate = file.bitrate {
                attributes.append((0, UInt32(max(0, bitrate))))
                attributes.append((2, file.isVBR ? 1 : 0))
            }
            if let duration = file.durationSeconds { attributes.append((1, UInt32(max(0, duration)))) }
        }
        u32(UInt32(attributes.count))
        for (code, value) in attributes {
            u32(code)
            u32(value)
        }
    }
}
