import CommonCrypto
import CryptoKit
import Foundation

/// A raw MeshCore packet:
///   header (2 bits version, 4 bits payload type, 2 bits route type)
///   · transport codes (4 bytes, transport routes only) · path length · path · payload
public struct MeshPacket: Hashable, Sendable {
    public enum Route: UInt8, Sendable, CaseIterable {
        case transportFlood = 0, flood = 1, direct = 2, transportDirect = 3
        public var isFlood: Bool { self == .flood || self == .transportFlood }
    }

    public enum PayloadType: UInt8, Sendable, CaseIterable {
        case request = 0, response, textMessage, ack, advert, groupText, groupData, anonRequest,
             path, trace, multipart, control, type12, type13, type14, rawCustom
        public var name: String {
            ["REQ", "RESPONSE", "TXT_MSG", "ACK", "ADVERT", "GRP_TXT", "GRP_DATA", "ANON_REQ",
             "PATH", "TRACE", "MULTIPART", "CONTROL", "UNK12", "UNK13", "UNK14", "RAW_CUSTOM"][Int(rawValue)]
        }
    }

    public let raw: Data
    public let route: Route
    public let payloadType: PayloadType
    public let version: Int
    public let transportCodes: Data?
    /// bytes per repeater ID in the path (1–3)
    public let hashSize: Int
    /// the repeaters it passed, first to last
    public let path: [Data]
    public let payload: Data

    public init?(raw: Data) {
        var r = ByteReader(raw)
        guard let header = try? r.u8() else { return nil }
        route = Route(rawValue: header & 0x03)!
        payloadType = PayloadType(rawValue: (header >> 2) & 0x0F)!
        version = Int(header >> 6) + 1
        if route == .transportFlood || route == .transportDirect {
            guard let t = try? r.bytes(4) else { return nil }
            transportCodes = t
        } else {
            transportCodes = nil
        }
        guard let pathLength = try? r.u8() else { return nil }
        let count = Int(pathLength & 0x3F), size = Int(pathLength >> 6) + 1
        guard let p = try? r.bytes(count * size) else { return nil }
        hashSize = size
        path = (0..<count).map { p.subdata(in: $0 * size..<($0 + 1) * size) }
        payload = r.rest()
        self.raw = Data(raw)
    }

    public var hops: Int { path.count }

    /// The same for every copy of a packet, whatever route it took: the first 4 bytes of SHA-256 of the
    /// payload, little-endian (the meshcore library's `pkt_hash`, MeshChat's `fp`).
    public var fingerprint: UInt32 {
        let d = Array(SHA256.hash(data: payload))
        return UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    }

    /// For an advert: who sent it and what it says.
    public var advert: Advert? { payloadType == .advert ? Advert(payload: payload) : nil }
}

/// A node announcing itself: key, time, signature, and app data (type, position, name).
public struct Advert: Hashable, Sendable {
    public let key: PublicKey
    /// by the sender's clock
    public let timestamp: UInt32
    public let type: NodeType
    public let position: Position?
    public let name: String

    init?(payload: Data) {
        var r = ByteReader(payload)
        guard let k = try? r.bytes(32), let key = PublicKey(k), let ts = try? r.u32(),
              (try? r.bytes(64)) != nil, let flags = try? r.u8() else { return nil }
        self.key = key
        timestamp = ts
        type = NodeType(raw: flags)
        var pos: Position?
        if flags & 0x10 != 0, let la = try? r.i32(), let lo = try? r.i32() { pos = Position(microdegreesLat: la, lon: lo) }
        position = pos
        if flags & 0x20 != 0 { _ = try? r.u16() }
        if flags & 0x40 != 0 { _ = try? r.u16() }
        name = flags & 0x80 != 0 ? r.restString() : ""
    }
}

/// Group (channel) message crypto. A channel's key is 16 bytes; a hashtag channel's is the first 16 bytes
/// of SHA-256 of its name ("#test"). Packets name the channel by the first byte of SHA-256 of the key, and
/// carry a 2-byte HMAC-SHA256 (keyed with the key padded to 32 bytes) over the AES-128-ECB ciphertext.
public enum ChannelCrypto {
    /// The key of a hashtag channel ("#name", lowercase as typed).
    public static func hashtagKey(_ name: String) -> Data {
        Data(SHA256.hash(data: Data(name.utf8))).prefix(16)
    }

    public static func hash(of key: Data) -> UInt8 { Array(SHA256.hash(data: key))[0] }

    /// A decrypted channel message: when it was sent, its flags, and "Sender: text".
    public struct Plain: Hashable, Sendable {
        public let timestamp: UInt32
        public let textType: TextType
        public let attempt: Int
        public let text: String
    }

    /// Decrypts a GRP_TXT payload (hash, MAC, ciphertext) with a channel key, if it's that channel's
    /// and the MAC checks out.
    public static func decryptGroupText(_ payload: Data, key: Data) -> Plain? {
        let p = Data(payload)
        guard p.count >= 3 + 16, (p.count - 3) % 16 == 0, p[0] == hash(of: key) else { return nil }
        let mac = p.subdata(in: 1..<3), cipher = p.subdata(in: 3..<p.count)
        var secret = key
        secret.append(Data(count: 32 - key.count))
        let check = Data(HMAC<SHA256>.authenticationCode(for: cipher, using: SymmetricKey(data: secret))).prefix(2)
        guard check == mac, let plain = aesECBDecrypt(cipher, key: key) else { return nil }
        var r = ByteReader(plain)
        guard let ts = try? r.u32(), let flags = try? r.u8() else { return nil }
        return Plain(timestamp: ts, textType: TextType(rawValue: flags >> 2) ?? .plain, attempt: Int(flags & 0x03), text: r.restString())
    }

    static func aesECBDecrypt(_ data: Data, key: Data) -> Data? {
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                }
            }
        }
        return status == kCCSuccess ? out.prefix(moved) : nil
    }
}
