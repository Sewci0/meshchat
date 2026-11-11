import Foundation

/// Reads the little-endian fields of a MeshCore frame. Reading past the end throws, so a short or
/// garbled frame fails cleanly instead of crashing.
struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = Data(data)   // rebased: indices start at 0
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    struct ShortFrame: Error {}

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ShortFrame() }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// A fixed-size text field: UTF-8 up to the first NUL. Invalid UTF-8 (a name cut mid-character by
    /// the radio) is repaired rather than dropped.
    mutating func string(_ n: Int) throws -> String {
        let b = try bytes(n)
        return Self.text(b)
    }

    /// Everything left, as text (up to a NUL, if any).
    mutating func restString() -> String {
        let b = data.subdata(in: offset..<data.count)
        offset = data.count
        return Self.text(b)
    }

    mutating func rest() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    static func text(_ b: Data) -> String {
        let end = b.firstIndex(of: 0) ?? b.endIndex
        return String(decoding: b[b.startIndex..<end], as: UTF8.self)
    }
}

/// Builds a frame field by field, little-endian.
struct ByteWriter {
    private(set) var data = Data()

    init(_ code: UInt8) { data.append(code) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func i8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func bytes(_ d: Data) { data.append(d) }

    /// A fixed-size text field, NUL-padded; cut on a character boundary so it stays valid UTF-8.
    mutating func string(_ s: String, size: Int) {
        var field = Data(s.utf8Prefix(maxBytes: size - 1).utf8)
        field.append(contentsOf: [UInt8](repeating: 0, count: size - field.count))
        data.append(field)
    }

    /// Text to the end of the frame (no terminator), at most `maxBytes`.
    mutating func text(_ s: String, maxBytes: Int) { data.append(contentsOf: s.utf8Prefix(maxBytes: maxBytes).utf8) }
}

extension String {
    /// The longest prefix that fits in `maxBytes` of UTF-8 without splitting a character.
    public func utf8Prefix(maxBytes: Int) -> String {
        if utf8.count <= maxBytes { return self }
        var out = ""
        var used = 0
        for ch in self {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }
}

extension Data {
    /// Lowercase hex, two characters a byte.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// From hex text (even length, 0-9a-f in either case); nil if it isn't hex.
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }
}
