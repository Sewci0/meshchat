import Foundation
import GRDB
import MeshCoreKit

/// Which conversation something belongs to, in the same form as the web app: "chan:<slot>",
/// "dm:<key hex>" (people and rooms), "watch:#name" (a hashtag channel read without joining it).
public enum ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    case channel(Int)
    case direct(PublicKey)
    case listened(String)

    public var description: String {
        switch self {
        case .channel(let i): "chan:\(i)"
        case .direct(let k): "dm:\(k.hex)"
        case .listened(let n): "watch:\(n)"
        }
    }

    public init?(_ s: String) {
        if s.hasPrefix("chan:"), let i = Int(s.dropFirst(5)) { self = .channel(i) }
        else if s.hasPrefix("dm:"), let k = PublicKey(hex: String(s.dropFirst(3))) { self = .direct(k) }
        else if s.hasPrefix("watch:#") { self = .listened(String(s.dropFirst(6))) }
        else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = ConversationID(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: s)) }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public enum Direction: String, Codable, Sendable { case incoming = "in", outgoing = "out" }

/// Where a message stands. Channel messages: sent → repeated (a repeater passed it on) or not heard.
/// DMs: sending → delivered (their radio confirmed it) or no ack.
public enum MessageStatus: String, Codable, Sendable {
    case received, sending, sent, repeated
    case notHeard = "not heard"
    case delivered
    case noAck = "no ack"
    case failed
}

/// One message, in or out.
public struct Message: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    /// when it arrived (or was sent), by this device's clock
    public var date: Date
    /// the sender's clock when sent (room posts: when posted)
    public var senderTimestamp: UInt32?
    public var conversation: ConversationID
    public var direction: Direction
    /// display name (room posts: the author; unknown authors: their key prefix)
    public var sender: String?
    public var text: String
    public var hops: Int?
    /// repeater IDs, first to last, hex
    public var path: String?
    public var hashSize: Int
    public var snr: Double?
    public var rssi: Int?
    public var status: MessageStatus
    /// times a repeater was heard passing on ours (channels)
    public var repeats: Int
    public var attempts: Int
    /// ours, DMs: per try, whether it went by flood
    public var triesFlood: [Bool]?
    public var ackTry: Int?
    public var roundTripMs: Int?
    /// room posts: the first 4 bytes of the author's key, hex
    public var author: String?
    /// its packet's fingerprint (every copy has the same)
    public var fingerprint: Int64?
    /// the radio settings it was on (channels are kept per network)
    public var network: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(date: Date = .now, senderTimestamp: UInt32?, conversation: ConversationID, direction: Direction, sender: String?,
                text: String, status: MessageStatus, hops: Int? = nil, path: String? = nil, hashSize: Int = 1, snr: Double? = nil,
                rssi: Int? = nil, network: String? = nil) {
        self.date = date; self.senderTimestamp = senderTimestamp; self.conversation = conversation; self.direction = direction
        self.sender = sender; self.text = text; self.status = status; self.hops = hops; self.path = path; self.hashSize = hashSize
        self.snr = snr; self.rssi = rssi; repeats = 0; attempts = 1; self.network = network
    }

    /// The network message `i` is on, when the one before it with a known network was on another: where a
    /// conversation's timeline shows the radio moved (messages from before networks were kept count
    /// neither way).
    public static func networkChange(_ messages: [Message], at i: Int) -> String? {
        guard let n = messages[i].network, !n.isEmpty else { return nil }
        guard let before = messages[..<i].last(where: { !($0.network ?? "").isEmpty })?.network else { return nil }
        return before == n ? nil : n
    }
}

/// A packet the radio heard (the RX log), kept for message details and repeater analysis.
public struct PacketRecord: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "packet"
    public var id: Int64?
    public var date: Date
    public var route: String
    public var type: String
    public var hops: Int
    public var path: String
    public var hashSize: Int
    public var snr: Double
    public var rssi: Int
    public var fingerprint: Int64
    public var raw: Data
    /// for channel packets: the channel ID (first byte of its key's hash)
    public var channelHash: Int?
    public var network: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A node whose advert the radio heard.
public struct HeardNode: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "heard"
    public var key: String
    public var name: String
    public var type: Int
    public var latitude: Double?
    public var longitude: Double?
    public var firstHeard: Date
    public var lastHeard: Date
    public var snr: Double
    public var rssi: Int
    public var hops: Int
    public var path: String
    public var hashSize: Int
    public var count: Int
    /// the network it was heard on (NetworkKey), "" if not known (heard before networks were kept): a node
    /// heard on two networks has a record for each
    public var network: String = ""
    public var id: String { key }

    /// One per node, the most recently heard (seconds compared, never `Date < Date`: see ContactTidy).
    public static func newestPerNode(_ all: [HeardNode]) -> [HeardNode] {
        var best: [String: HeardNode] = [:]
        for h in all where (best[h.key]?.lastHeard.timeIntervalSince1970 ?? -.infinity) < h.lastHeard.timeIntervalSince1970 { best[h.key] = h }
        return Array(best.values)
    }
}

/// What's known about a contact's saved route over time (see the web app's route history).
public struct RouteHistory: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "route"
    public var key: String
    /// the route as last learned: hops, hash size, path hex (nil after a reset)
    public var current: StoredPath?
    public var learned: Date?
    public var confirmed: Date?
    public var learns: Int
    public var changes: Int
    public var previous: StoredPath?
    public var previousSince: Date?
    public var reset: Date?
    /// "you", "retry" (a DM's last try) or "app"
    public var resetBy: String?
    /// the PATH packet that brought the current route
    public var viaPacket: Int64?
    public var viaSNR: Double?
    public var viaRSSI: Int?
    public var viaHops: Int?

    public init(key: String) { self.key = key; learns = 0; changes = 0 }
}

public struct StoredPath: Codable, Sendable, Hashable {
    public var hops: Int
    public var hashSize: Int
    public var path: String

    public init(_ p: OutPath) { hops = p.hops.count; hashSize = p.hashSize; path = p.bytes.hex }
}

/// A room server joined from here.
public struct RoomMembership: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "room"
    public var key: String
    public var joined: Date?
    public var loginAt: Date?
    public var left: Bool
    public var leftAt: Date?
    /// guest, read-only, read-write, admin (nil: the room didn't say)
    public var role: String?
    public var admin: Bool
}

/// The latest login, status and neighbour answer from a repeater or room server.
public struct LiveAnswer: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "live"
    public var key: String
    public var date: Date
    public var ok: Bool
    public var error: String?
    public var role: String?
    public var admin: Bool
    public var serverTime: UInt32?
    public var firmwareLevel: Int?
    /// the raw stats (see NodeStatus)
    public var status: Data?
    public var neighbours: [StoredNeighbour]?
    public var neighboursTotal: Int?
}

/// A node's readings (battery, temperature, position…) as last asked for, or why there were none.
public struct TelemetryAnswer: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "telemetry"
    public var key: String
    public var date: Date
    /// as it came (Cayenne LPP); nil when it didn't answer
    public var data: Data?
    public var error: String?

    public init(key: String, date: Date, data: Data? = nil, error: String? = nil) {
        self.key = key; self.date = date; self.data = data; self.error = error
    }

    public var readings: [TelemetryReading] { data.map(Telemetry.decode) ?? [] }
}

public struct StoredNeighbour: Codable, Sendable, Hashable {
    public var prefix: String
    public var secondsAgo: Int
    public var snr: Double
}

/// A hashtag channel read without joining it.
public struct ListenedChannel: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "listened"
    public var name: String
    public var added: Date
}

/// The newest message in each conversation (for the chat list).
public struct ConversationSummary: Codable, Sendable, Hashable, FetchableRecord {
    public var conversation: ConversationID
    public var lastID: Int64
    public var count: Int
    public var lastDate: Date
}
