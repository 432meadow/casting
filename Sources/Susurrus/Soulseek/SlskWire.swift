import Compression
import Foundation

/// Low-level Soulseek wire format: little-endian integers, u32-length-prefixed strings,
/// u32-length-prefixed frames, and the zlib wrapping used by file lists and search results.
/// Layouts follow Nicotine+ 3.3.10's `doc/SLSKPROTOCOL.md`.

struct SlskError: LocalizedError, CustomStringConvertible {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}

// MARK: Writer

struct SlskWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }

    mutating func u32(_ value: UInt32) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value))
        u32(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func string(_ value: String) {
        bytes(Data(value.utf8))
    }

    /// Search terms are sent latin-1 when possible, matching official clients and Nicotine+
    /// (older clients don't decode UTF-8).
    mutating func legacyString(_ value: String) {
        bytes(value.data(using: .isoLatin1) ?? Data(value.utf8))
    }

    mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    /// Appends already-encoded bytes without a length prefix.
    mutating func raw(_ value: Data) {
        data.append(value)
    }
}

// MARK: Reader

struct SlskReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }
    var isAtEnd: Bool { remaining == 0 }

    private mutating func take(_ count: Int) throws -> Data {
        guard remaining >= count else { throw SlskError(message: "message truncated") }
        defer { offset += count }
        return data[offset ..< offset + count]
    }

    mutating func u8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func bool() throws -> Bool {
        try u8() != 0
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        var value: UInt32 = 0
        for (i, byte) in b.enumerated() { value |= UInt32(byte) << (8 * i) }
        return value
    }

    mutating func u64() throws -> UInt64 {
        let low = try u32()
        let high = try u32()
        return UInt64(high) << 32 | UInt64(low)
    }

    /// File sizes: Soulseek NS sends garbage in the high half of >2 GiB sizes
    /// (high u32 = 0xFFFFFFFF); fall back to the low half, as Nicotine+ does.
    mutating func fileSize() throws -> UInt64 {
        let value = try u64()
        if value >> 32 == 0xFFFF_FFFF { return value & 0xFFFF_FFFF }
        return value
    }

    mutating func string() throws -> String {
        let bytes = try take(Int(try u32()))
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    /// A u32 length, then that many raw bytes (pictures in user info).
    mutating func bytes() throws -> Data {
        Data(try take(Int(try u32())))
    }

    /// IPv4 addresses are a u32 whose bytes are reversed relative to network order.
    mutating func ipv4() throws -> String {
        let b = Data(try take(4))
        return "\(b[3]).\(b[2]).\(b[1]).\(b[0])"
    }
}

// MARK: Frame splitting

/// Accumulates stream bytes and yields complete u32-length-prefixed frames
/// (the prefix is stripped; the returned payload starts with the message code).
struct SlskFrameBuffer {
    static let maxFrameSize = 16 << 20

    private var buffer = Data()

    mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        var length: UInt32 = 0
        for i in 0 ..< 4 { length |= UInt32(buffer[buffer.startIndex + i]) << (8 * i) }
        guard length <= UInt32(Self.maxFrameSize) else {
            throw SlskError(message: "oversized frame (\(length) bytes)")
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let frame = Data(buffer[buffer.startIndex + 4 ..< buffer.startIndex + total])
        buffer = Data(buffer.dropFirst(total))
        return frame
    }

    /// Hands over whatever is buffered, unframed. File (`F`) connections switch to raw bytes
    /// after their init frame, so anything already read belongs to the file stream.
    mutating func drainRemaining() -> Data {
        defer { buffer = Data() }
        return buffer
    }
}

// MARK: zlib

/// Search results and share lists travel zlib-wrapped (RFC 1950: 2-byte header,
/// deflate body, adler32 trailer). Apple's Compression handles the raw deflate part.
enum SlskZlib {
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw SlskError(message: "compressed payload too short") }
        let header = data[data.startIndex]
        let flags = data[data.startIndex + 1]
        guard header & 0x0F == 8, flags & 0x20 == 0 else {
            throw SlskError(message: "unsupported zlib header")
        }
        return try run(Data(data.dropFirst(2)), operation: COMPRESSION_STREAM_DECODE)
    }

    static func deflate(_ data: Data) throws -> Data {
        var out = Data([0x78, 0x9C])
        out += try run(data, operation: COMPRESSION_STREAM_ENCODE)
        var adler = adler32(data).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    private static func run(_ input: Data, operation: compression_stream_operation) throws -> Data {
        var output = Data()
        let bufferSize = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SlskError(message: "compression init failed")
        }
        defer { compression_stream_destroy(streamPointer) }

        try input.withUnsafeBytes { (inputBytes: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = inputBytes.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = input.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(
                    streamPointer,
                    streamPointer.pointee.src_size == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                )
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw SlskError(message: "corrupt compressed data")
                }
                output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
                guard output.count <= SlskFrameBuffer.maxFrameSize else {
                    throw SlskError(message: "decompressed payload too large")
                }
                if status == COMPRESSION_STATUS_END { break }
            }
        }
        return output
    }
}
