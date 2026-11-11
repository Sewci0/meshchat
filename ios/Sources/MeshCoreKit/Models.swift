import Foundation

/// A node's 32-byte public key: its identity on the mesh.
public struct PublicKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init?(_ bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = Data(bytes)
    }

    public init?(hex: String) {
        guard let d = Data(hex: hex) else { return nil }
        self.init(d)
    }

    public var hex: String { bytes.hex }
    /// The first `n` bytes: messages and paths name nodes by a prefix of their key.
    public func prefix(_ n: Int) -> Data { bytes.prefix(n) }
    public var description: String { String(hex.prefix(8)) }
}

/// What a node advertises itself as.
public enum NodeType: UInt8, Sendable, Codable, CaseIterable {
    case unknown = 0, companion = 1, repeater = 2, room = 3, sensor = 4

    public init(raw: UInt8) { self = NodeType(rawValue: raw & 0x0F) ?? .unknown }
}

/// A saved route to a contact: the repeaters a direct message goes through, first to last. Each is
/// named by the first 1, 2 or 3 bytes of its key (the path hash size).
public struct OutPath: Hashable, Sendable, Codable {
    public let hashSize: Int
    public let hops: [Data]

    public init(hashSize: Int, hops: [Data]) { self.hashSize = hashSize; self.hops = hops }

    /// MeshCore's path length byte: hop count in the low 6 bits, hash size − 1 in the top 2.
    /// 0xFF means no saved route (messages flood).
    static func decode(lengthByte: UInt8, path: Data) -> OutPath? {
        guard lengthByte != 0xFF else { return nil }
        let count = Int(lengthByte & 0x3F), size = Int(lengthByte >> 6) + 1
        guard count * size <= path.count else { return nil }
        let p = Data(path)
        return OutPath(hashSize: size, hops: (0..<count).map { p.subdata(in: $0 * size..<($0 + 1) * size) })
    }

    public var lengthByte: UInt8 { UInt8(hops.count) | UInt8(hashSize - 1) << 6 }
    public var bytes: Data { hops.reduce(Data(), +) }
}

/// A position from an advert, if it carried one (0,0 and out-of-range values mean none).
public struct Position: Hashable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double

    init?(microdegreesLat lat: Int32, lon: Int32) {
        let la = Double(lat) / 1e6, lo = Double(lon) / 1e6
        guard !(lat == 0 && lon == 0), abs(la) <= 90, abs(lo) <= 180 else { return nil }
        latitude = la
        longitude = lo
    }

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A contact as the radio stores it.
public struct Contact: Hashable, Sendable, Codable, Identifiable {
    public let key: PublicKey
    public var type: NodeType
    public var flags: UInt8
    /// nil: no saved route, messages flood
    public var outPath: OutPath?
    public var name: String
    /// when it last advertised, by its own clock (which may be wrong)
    public var lastAdvert: UInt32
    public var position: Position?
    /// when the radio last changed this record, by the radio's clock
    public var lastModified: UInt32

    public var id: PublicKey { key }
    public var isFavourite: Bool { flags & 0x01 != 0 }

    public init(key: PublicKey, type: NodeType, flags: UInt8 = 0, outPath: OutPath? = nil, name: String,
                lastAdvert: UInt32 = 0, position: Position? = nil, lastModified: UInt32 = 0) {
        self.key = key; self.type = type; self.flags = flags; self.outPath = outPath; self.name = name
        self.lastAdvert = lastAdvert; self.position = position; self.lastModified = lastModified
    }
}

/// LoRa settings. Radios hear each other only with the same frequency, bandwidth and spreading factor.
public struct RadioSettings: Hashable, Sendable, Codable {
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    public var codingRate: Int

    public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int) {
        self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor; self.codingRate = codingRate
    }
}

/// The radio's own identity and settings (the reply to app start).
public struct SelfInfo: Hashable, Sendable, Codable {
    public var key: PublicKey
    public var name: String
    public var txPower: Int
    public var maxTxPower: Int
    public var position: Position?
    public var radio: RadioSettings
    /// 0: adverts carry no location
    public var advertLocationPolicy: UInt8
    /// contacts are added only by hand (not from every advert heard)
    public var manualAddContacts: Bool
    /// the settings the radio changes together (to change one, send the others back as they were)
    public var otherParams: OtherParams?
}

/// Settings the radio sets in one command: whether contacts are added by hand, who may read its
/// telemetry, whether adverts carry its position, and multiple ACKs.
public struct OtherParams: Hashable, Sendable, Codable {
    public var manualAddContacts: UInt8
    public var telemetryModes: UInt8
    /// 0: adverts carry no position; 1: they carry the node's position
    public var locationPolicy: UInt8
    public var multiAcks: UInt8

    public init(manualAddContacts: UInt8, telemetryModes: UInt8, locationPolicy: UInt8, multiAcks: UInt8) {
        self.manualAddContacts = manualAddContacts; self.telemetryModes = telemetryModes
        self.locationPolicy = locationPolicy; self.multiAcks = multiAcks
    }
}

/// How the radio paces what it sends (advanced): the base of its random delay before passing on a
/// packet, and the airtime factor (how long it stays quiet after sending, relative to the airtime).
public struct TuningParams: Hashable, Sendable, Codable {
    public var rxDelayBase: Double
    public var airtimeFactor: Double

    public init(rxDelayBase: Double, airtimeFactor: Double) {
        self.rxDelayBase = rxDelayBase
        self.airtimeFactor = airtimeFactor
    }
}

/// Which nodes the radio adds as contacts by itself when their adverts arrive (when it doesn't add
/// them only by hand), how many hops away at most, and whether a full list makes room by dropping the
/// oldest that isn't a favourite.
public struct AutoAddConfig: Hashable, Sendable, Codable {
    public var flags: UInt8
    /// 0: any distance
    public var maxHops: Int

    public static let overwriteOldest: UInt8 = 0x01, people: UInt8 = 0x02, repeaters: UInt8 = 0x04, rooms: UInt8 = 0x08, sensors: UInt8 = 0x10

    public init(flags: UInt8, maxHops: Int) {
        self.flags = flags
        self.maxHops = maxHops
    }

    public func has(_ flag: UInt8) -> Bool { flags & flag != 0 }
}

/// Frequencies on which the radio may repeat (pass on) other nodes' packets itself: legal limits on
/// duty cycle keep that to a few frequencies.
public struct FrequencyRange: Hashable, Sendable, Codable {
    public let lowerKHz: UInt32
    public let upperKHz: UInt32

    public init(lowerKHz: UInt32, upperKHz: UInt32) {
        self.lowerKHz = lowerKHz
        self.upperKHz = upperKHz
    }

    public func contains(mhz: Double) -> Bool {
        let khz = UInt32((mhz * 1000).rounded())
        return khz >= lowerKHz && khz <= upperKHz
    }
}

/// The flood region the radio puts on what it floods by default (regions limit how far floods travel):
/// a name and its 16-byte key.
public struct FloodScope: Hashable, Sendable, Codable {
    public var name: String
    public var key: Data

    public init(name: String, key: Data) {
        self.name = name
        self.key = key
    }
}

/// Who may ask the radio for its telemetry, per kind: battery and such (base), its location, and its
/// environment sensors. Packed two bits each into one byte.
public struct TelemetryModes: Hashable, Sendable, Codable {
    public enum Mode: UInt8, CaseIterable, Sendable, Codable {
        case nobody = 0, allowed = 1, everyone = 2
    }

    public var base: Mode
    public var location: Mode
    public var environment: Mode

    public init(base: Mode, location: Mode, environment: Mode) {
        self.base = base; self.location = location; self.environment = environment
    }

    public init(byte: UInt8) {
        base = Mode(rawValue: byte & 0x03) ?? .nobody
        location = Mode(rawValue: (byte >> 2) & 0x03) ?? .nobody
        environment = Mode(rawValue: (byte >> 4) & 0x03) ?? .nobody
    }

    public var byte: UInt8 { base.rawValue | location.rawValue << 2 | environment.rawValue << 4 }
}

/// The radio's firmware and limits (the reply to the device query).
public struct DeviceInfo: Hashable, Sendable, Codable {
    public var firmwareCode: Int
    public var maxContacts: Int
    public var maxChannels: Int
    public var blePin: UInt32
    public var buildDate: String
    public var model: String
    public var version: String
    /// repeating other nodes' packets (v9+)
    public var repeatEnabled: Bool?
    /// path hash size − 1 for messages it sends (v10+)
    public var pathHashMode: Int?
}

/// One of the radio's channel slots.
public struct ChannelInfo: Hashable, Sendable, Codable {
    public let index: Int
    public var name: String
    /// the 16-byte key; for a hashtag channel, the first 16 bytes of SHA-256 of its name
    public var secret: Data
    public var isEmpty: Bool { name.isEmpty }
    /// how packets name the channel: the first byte of SHA-256 of the key
    public var hash: UInt8 { ChannelCrypto.hash(of: secret) }

    public init(index: Int, name: String, secret: Data) {
        self.index = index; self.name = name; self.secret = secret
    }
}

/// The text kinds a message can carry (the low bits of its flags byte are the attempt number).
public enum TextType: UInt8, Sendable, Codable {
    case plain = 0, cliData = 1, signedPlain = 2
}

/// A direct message (or a room post), as the radio hands it over.
public struct ContactMessage: Hashable, Sendable, Codable {
    /// the first 6 bytes of the sender's key (for a room post: the room's)
    public let senderPrefix: Data
    /// at the last hop; reported only by protocol v3+
    public let snr: Double?
    /// hops it came over when flooded; nil when it came direct (on a saved route)
    public let floodHops: Int?
    public let pathHashSize: Int
    public let textType: TextType
    /// the sender's clock when sent
    public let senderTimestamp: UInt32
    /// room posts: the first 4 bytes of the author's key
    public let authorPrefix: Data?
    public let text: String
}

/// A channel message, as the radio hands it over ("name: text").
public struct ChannelMessage: Hashable, Sendable, Codable {
    public let channelIndex: Int
    public let snr: Double?
    public let floodHops: Int?
    public let pathHashSize: Int
    public let textType: TextType
    public let senderTimestamp: UInt32
    /// as sent: "Sender name: message"
    public let text: String

    /// The sender's display name and the message, split at the first ": ".
    public var parts: (sender: String?, body: String) { Self.split(text) }

    /// "Name: text" → ("Name", "text"); text without a ": " has no sender.
    public static func split(_ text: String) -> (sender: String?, body: String) {
        guard let r = text.range(of: ": ") else { return (nil, text) }
        return (String(text[..<r.lowerBound]), String(text[r.upperBound...]))
    }
}

public enum ReceivedMessage: Hashable, Sendable {
    case contact(ContactMessage)
    case channel(ChannelMessage)
}

/// The radio's answer to a send: whether it went by flood, the ACK code to expect, and how long to wait.
public struct SentInfo: Hashable, Sendable {
    public let flood: Bool
    /// for a DM, the code its ACK will carry; for requests, the tag the reply carries
    public let tag: UInt32
    public let timeoutMs: UInt32
}

/// A trace's answer: the SNR at each repeater on the way, and how well it came back here.
public struct TraceResult: Hashable, Sendable {
    public let tag: UInt32
    public let auth: UInt32
    public let flags: UInt8
    public let hashes: Data
    public let snrs: [Double]
    public let finalSNR: Double
}

/// A control packet heard straight from a node: how well it arrived, and what it says.
public struct ControlData: Hashable, Sendable {
    static let discoverRequest: UInt8 = 0x80, discoverResponse: UInt8 = 0x90

    public let snr: Double
    public let rssi: Int
    public let pathLength: Int
    public let payload: Data

    /// A node-discovery answer to `tag`: the node's type, how well it heard you, and its key (or prefix).
    public func discoveryAnswer(tag: UInt32) -> DiscoveryAnswer? {
        var r = ByteReader(payload)
        guard let head = try? r.u8(), head & 0xF0 == Self.discoverResponse, let heard = try? r.i8(), let t = try? r.u32(), t == tag,
              r.remaining >= 8 else { return nil }
        return DiscoveryAnswer(nodeType: NodeType(raw: head & 0x0F), keyPrefix: r.rest(), snrThere: Double(heard) / 4, snrHere: snr, rssi: rssi)
    }
}

/// A node that answered "which repeaters hear me?".
public struct DiscoveryAnswer: Hashable, Sendable {
    public let nodeType: NodeType
    /// 8 bytes of its key (or all 32)
    public let keyPrefix: Data
    /// how well it heard you
    public let snrThere: Double
    /// how well you heard its answer
    public let snrHere: Double
    public let rssi: Int

    public init(nodeType: NodeType, keyPrefix: Data, snrThere: Double, snrHere: Double, rssi: Int) {
        self.nodeType = nodeType; self.keyPrefix = keyPrefix; self.snrThere = snrThere; self.snrHere = snrHere; self.rssi = rssi
    }
}

/// A login answer from a repeater or room server.
public struct LoginResult: Hashable, Sendable {
    public let keyPrefix: Data
    /// 1: admin (legacy flag)
    public let permissions: UInt8
    /// newer firmware: the server's clock, the ACL role (0 guest, 1 read-only, 2 read-write, 3 admin)
    /// and its firmware level
    public let serverTime: UInt32?
    public let aclRole: UInt8?
    public let firmwareLevel: UInt8?
}

public struct BatteryInfo: Hashable, Sendable {
    public let millivolts: Int
    public let storageUsedKB: Int
    public let storageTotalKB: Int
}

/// A packet the radio heard, as it heard it (the RX log).
public struct RxLogEntry: Hashable, Sendable {
    public let snr: Double
    public let rssi: Int
    public let raw: Data
    public var packet: MeshPacket? { MeshPacket(raw: raw) }
}
