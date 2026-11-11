import Foundation
import MeshCoreKit

/// A packet byte by byte, for message details: header (route, type, version), transport codes, path
/// length (ID size, hops), path, then the payload — labelled for channel and direct messages.
public struct PacketAnatomy: Sendable {
    public enum Part: String, Sendable { case header, transport, path, address, mac, cipher, payload }

    public struct Field: Hashable, Sendable, Identifiable {
        public let label: String
        public let hex: String
        public let note: String
        public let part: Part
        public var id: String { label }
    }

    /// MeshCore's limits: a packet, its payload, the path field.
    public static let maxPacket = 255, maxPayload = 184, maxPath = 64

    public let fields: [Field]
    public let total: Int
    /// header, transport codes, path length and path: what the routing costs
    public let routing: Int
    public let payload: Int
    /// AES blocks for messages
    public let cipher: Int
    public let hops: [String]
    public let hashSize: Int
    /// the header byte, split: version (top 2 bits), payload type (4), route type (bottom 2)
    public let headerByte: UInt8
    public let version: Int
    public let typeName: String
    public let routeName: String
    /// the path length byte: ID size − 1 (top 2 bits), hops (bottom 6)
    public let pathLengthByte: UInt8
    /// how many hops the path field (64 bytes) can hold with this ID size
    public var maxHops: Int { Self.maxPath / max(1, hashSize) }

    public init?(raw: Data) {
        guard let p = MeshPacket(raw: raw) else { return nil }
        var f: [Field] = []
        let b = Data(raw)
        f.append(Field(label: "Header", hex: b.prefix(1).hex, note: "\(Self.routeName(p.route)) route · \(p.payloadType.name) · version \(p.version)", part: .header))
        var i = 1
        if let t = p.transportCodes {
            f.append(Field(label: "Transport codes", hex: t.hex, note: "region scope: which areas' repeaters may pass it on", part: .transport)); i += 4
        }
        f.append(Field(label: "Path length", hex: b.subdata(in: i..<i + 1).hex,
                       note: "\(p.hops) \(p.hops == 1 ? "hop" : "hops") × \(p.hashSize)-byte repeater IDs", part: .header))
        i += 1
        if p.hops > 0 {
            f.append(Field(label: "Path", hex: p.path.map(\.hex).joined(), note: "the repeaters it passed, first to last", part: .path))
            i += p.hops * p.hashSize
        }
        let pay = p.payload
        var cipher = 0
        if p.payloadType == .groupText, pay.count >= 3 {
            cipher = pay.count - 3
            f.append(Field(label: "Channel ID", hex: pay.prefix(1).hex, note: "first byte of SHA-256 of the channel key", part: .address))
            f.append(Field(label: "MAC", hex: pay.subdata(in: pay.startIndex + 1..<pay.startIndex + 3).hex, note: "HMAC-SHA256, 2 bytes: proves the key is right", part: .mac))
            f.append(Field(label: "Ciphertext", hex: pay.dropFirst(3).hex, note: "AES-128, \(cipher / 16) \(cipher == 16 ? "block" : "blocks")", part: .cipher))
        } else if p.payloadType == .textMessage, pay.count >= 4 {
            cipher = pay.count - 4
            f.append(Field(label: "To", hex: pay.prefix(1).hex, note: "first byte of the recipient's key", part: .address))
            f.append(Field(label: "From", hex: pay.dropFirst().prefix(1).hex, note: "first byte of the sender's key", part: .address))
            f.append(Field(label: "MAC", hex: pay.dropFirst(2).prefix(2).hex, note: "HMAC-SHA256, 2 bytes, with your shared secret", part: .mac))
            f.append(Field(label: "Ciphertext", hex: pay.dropFirst(4).hex, note: "AES-128, \(cipher / 16) \(cipher == 16 ? "block" : "blocks")", part: .cipher))
        } else if !pay.isEmpty {
            f.append(Field(label: "Payload", hex: pay.hex, note: "\(pay.count) bytes", part: .payload))
        }
        fields = f
        headerByte = b[b.startIndex]
        version = p.version
        typeName = p.payloadType.name
        routeName = Self.routeName(p.route)
        pathLengthByte = b[b.startIndex + (p.transportCodes == nil ? 1 : 5)]
        total = b.count
        routing = i
        payload = pay.count
        self.cipher = cipher
        hops = p.path.map(\.hex)
        hashSize = p.hashSize
    }

    static func routeName(_ r: MeshPacket.Route) -> String {
        switch r {
        case .transportFlood: "transport flood"
        case .flood: "flood"
        case .direct: "direct"
        case .transportDirect: "transport direct"
        }
    }

    /// What carrying the path costs on air: the packet's airtime less the same packet without its path.
    public func pathAirtimeMs(_ r: RadioSettings) -> Double {
        let pathBytes = hops.count * hashSize
        return pathBytes > 0 ? Self.airtimeMs(bytes: total, r) - Self.airtimeMs(bytes: total - pathBytes, r) : 0
    }

    /// Time on air (ms) for `bytes` at these settings: RadioLib's SX126x formula with MeshCore's preamble
    /// (32 symbols at SF8 and below, else 16), explicit header and CRC.
    public static func airtimeMs(bytes: Int, _ r: RadioSettings) -> Double {
        let sf = r.spreadingFactor
        let tsym = pow(2, Double(sf)) / r.bandwidthKHz
        let preamble = sf <= 8 ? 32.0 : 16.0
        let low = sf <= 6
        let ldro = tsym > 16
        let bits = Double(8 * bytes + 16 - 4 * sf + (low ? 0 : 8) + 20)
        let symbols = max(0, (bits / Double(4 * (ldro ? sf - 2 : sf))).rounded(.up)) * Double(r.codingRate)
        return (preamble + 8 + (low ? 6.25 : 4.25) + symbols) * tsym
    }
}
