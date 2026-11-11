import Foundation
import MeshCoreKit

/// Everything known about one message: the copies of its packet the radio heard (one per route, or each
/// repeater that passed ours on), in the order heard.
public struct MessageInfo: Sendable {
    public struct Copy: Hashable, Sendable, Identifiable {
        public let packet: PacketRecord
        /// after the first copy
        public let after: TimeInterval
        public var id: Int64 { packet.id ?? 0 }
    }

    public let message: Message
    public let copies: [Copy]
    /// the sender's clock against this device's when it arrived (positive: it arrived later)
    public var clockSkew: TimeInterval? {
        message.senderTimestamp.map { message.date.timeIntervalSince1970 - Double($0) }
    }
    /// distinct routes among the copies
    public var routes: Int { Set(copies.map(\.packet.path)).count }

    public init(message: Message, store: Store) {
        self.message = message
        let packets = (message.fingerprint.flatMap { try? store.copies(of: $0) }) ?? []
        let first = packets.first?.date
        copies = packets.map { p in Copy(packet: p, after: first.map { p.date.timeIntervalSince($0) } ?? 0) }
    }
}

/// A room server, for the rooms browser: known from contacts and heard adverts (offline; every room
/// listed is on your radio settings, since the radio decodes nothing else).
public struct RoomEntry: Hashable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let contact: Contact?
    public let heard: HeardNode?
    public let membership: RoomMembership?
    public let position: Position?
    public let km: Double?
    public let bearing: String?
    public let posts: Int
    public let lastPost: Date?
    /// when its last advert reached you (our clock if heard lately, else its own, unless that's ahead)
    public let lastAdvert: Date?
    /// joined here (and not left), or posts arriving from it (joined from another app)
    public var isMember: Bool { (membership.map { !$0.left } ?? false) || (membership?.left != true && posts > 0) }
    public var id: String { key }

    public static func all(contacts: [Contact], heard: [HeardNode], rooms: [String: RoomMembership],
                           conversations: [ConversationID: ConversationSummary], home: Position?, now: Date = .now) -> [RoomEntry] {
        var out: [String: RoomEntry] = [:]
        func add(key: String, name: String, contact: Contact?, heard: HeardNode?) {
            let pos = contact?.position ?? heard.flatMap { h in h.latitude.flatMap { la in h.longitude.map { Position(latitude: la, longitude: $0) } } }
            let conv = PublicKey(hex: key).map { ConversationID.direct($0) }
            let summary = conv.flatMap { conversations[$0] }
            out[key] = RoomEntry(key: key, name: name, contact: contact, heard: heard, membership: rooms[key], position: pos,
                                 km: pos.flatMap { p in home.map { Geo.km($0, p) } },
                                 bearing: pos.flatMap { p in home.flatMap { h in Geo.km(h, p) >= 1 ? Geo.bearing(h, p) : nil } },
                                 posts: summary?.count ?? 0, lastPost: summary?.lastDate,
                                 lastAdvert: heard?.lastHeard ?? contact.flatMap { c in
                                     c.lastAdvert > 0 && Double(c.lastAdvert) <= now.timeIntervalSince1970 + 300 ? Date(timeIntervalSince1970: Double(c.lastAdvert)) : nil
                                 })
        }
        let heardByKey = Dictionary(heard.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for c in contacts where c.type == .room { add(key: c.key.hex, name: c.name, contact: c, heard: heardByKey[c.key.hex]) }
        for h in heard where h.type == Int(NodeType.room.rawValue) && out[h.key] == nil { add(key: h.key, name: h.name, contact: nil, heard: h) }
        // joined first, then nearest
        return out.values.sorted { ($0.isMember ? 0 : 1, $0.km ?? .infinity, $0.name) < ($1.isMember ? 0 : 1, $1.km ?? .infinity, $1.name) }
    }

    public enum Sort: String, CaseIterable, Sendable { case distance, heard, name, posts }

    /// The room browser's list: joined rooms first whatever the order (they're the ones you use), then
    /// by `sort`; `joinedOnly` keeps just those.
    public static func shown(_ entries: [RoomEntry], query: String = "", joinedOnly: Bool = false, sort: Sort = .distance) -> [RoomEntry] {
        func before(_ a: RoomEntry, _ b: RoomEntry) -> Bool {
            if a.isMember != b.isMember { return a.isMember }
            switch sort {
            case .distance: return (a.km ?? .infinity, a.name) < (b.km ?? .infinity, b.name)
            case .heard: return (a.lastAdvert ?? .distantPast, b.name) > (b.lastAdvert ?? .distantPast, a.name)
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .posts: return (a.posts, a.lastPost ?? .distantPast) > (b.posts, b.lastPost ?? .distantPast)
            }
        }
        return entries.filter { e in (!joinedOnly || e.isMember) && (query.isEmpty || e.name.localizedCaseInsensitiveContains(query)) }
            .sorted(by: before)
    }
}

/// What a role lets you do in a room.
public enum RoomRole {
    public static func label(_ role: String?) -> String {
        switch role {
        case "guest": String(localized: "Guest")
        case "read-only": String(localized: "Read only")
        case "read-write": String(localized: "Member")
        case "admin": String(localized: "Admin")
        default: String(localized: "Joined")
        }
    }

    public static func canPost(_ role: String?) -> Bool { role == nil || role == "read-write" || role == "admin" }

    public static func explanation(_ role: String?) -> String {
        switch role {
        case "guest": String(localized: "You can read the posts. Posting needs the room's password.")
        case "read-only": String(localized: "You can read the posts, not post.")
        case "admin": String(localized: "You can read, post and manage the room.")
        default: String(localized: "You can read and post.")
        }
    }
}

/// The points and lines the map shows: nodes with a known position, home, and on request a route.
public struct MapContent: Sendable {
    public struct Point: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case person, repeater, room, sensor, home }
        public let id: String
        public let name: String
        public let kind: Kind
        public let position: Position
        public let isContact: Bool
        public let lastHeard: Date?
    }

    public let points: [Point]

    public init(contacts: [Contact], heard: [HeardNode], home: Position?) {
        var out: [String: Point] = [:]
        func kind(_ t: NodeType) -> Point.Kind { switch t { case .repeater: .repeater; case .room: .room; case .sensor: .sensor; default: .person } }
        for h in heard {
            guard let la = h.latitude, let lo = h.longitude else { continue }
            out[h.key] = Point(id: h.key, name: h.name, kind: kind(NodeType(raw: UInt8(h.type))), position: Position(latitude: la, longitude: lo),
                               isContact: false, lastHeard: h.lastHeard)
        }
        for c in contacts {
            guard let p = c.position ?? out[c.key.hex]?.position else { continue }
            out[c.key.hex] = Point(id: c.key.hex, name: c.name, kind: kind(c.type), position: p, isContact: true, lastHeard: out[c.key.hex]?.lastHeard)
        }
        if let home { out["home"] = Point(id: "home", name: String(localized: "Home"), kind: .home, position: home, isContact: false, lastHeard: nil) }
        points = out.values.sorted { $0.id < $1.id }
    }
}

/// One row of the nodes list: a contact, a node only heard, or both (as the web app's nodes page).
public struct NodeRow: Hashable, Sendable, Identifiable {
    public enum Sort: String, CaseIterable, Sendable { case heard, name, distance, hops }
    /// all, only the radio's contacts, or only nodes heard that aren't contacts
    public enum Show: String, CaseIterable, Sendable { case all, contacts, heardOnly }

    public let key: String
    public let name: String
    public let type: NodeType
    public let contact: Contact?
    public let heard: HeardNode?
    public let position: Position?
    public let km: Double?
    /// as last heard, or the saved route's length
    public let hops: Int?
    /// when its advert was last heard here, or else when it last advertised by its own clock
    public let lastSeen: Date?
    public var id: String { key }

    /// Whether the list shows it: a contact or not, as `show` asks, and (with `hideStale`) heard within a month.
    public func shown(_ show: Show, hideStale: Bool, now: Date = .now) -> Bool {
        switch show {
        case .all: break
        case .contacts: if contact == nil { return false }
        case .heardOnly: if contact != nil { return false }
        }
        guard hideStale else { return true }
        // (seconds compared, not `Date < Date`, as above)
        return lastSeen.map { now.timeIntervalSince($0) < 30 * 86400 } ?? false
    }

    public static func all(contacts: [Contact], heard: [HeardNode], home: Position?, type: NodeType? = nil,
                           query: String = "", sort: Sort = .heard, now: Date = .now) -> [NodeRow] {
        let heardByKey = Dictionary(heard.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [String: NodeRow] = [:]
        func make(_ key: String, _ name: String, _ t: NodeType, _ c: Contact?, _ h: HeardNode?) -> NodeRow {
            let pos = c?.position ?? h.flatMap { h in h.latitude.flatMap { la in h.longitude.map { Position(latitude: la, longitude: $0) } } }
            // when the radio last updated the contact (its own clock, which the app keeps set), else the node's
            // advert time, unless that's in the future: a node with a wrong clock would sort above everything
            let updated = c.flatMap { $0.lastModified > 0 ? Date(timeIntervalSince1970: Double($0.lastModified)) : nil }
            // (seconds compared, not `Date <= Date`: the iOS 27.2 SDK calls a new Foundation function for
            // that, missing from 27.2 betas, where it crashes)
            let advert = c.flatMap { $0.lastAdvert > 0 ? Date(timeIntervalSince1970: Double($0.lastAdvert)) : nil }
                .flatMap { $0.timeIntervalSince(now) <= 300 ? $0 : nil }
            return NodeRow(key: key, name: name, type: t, contact: c, heard: h, position: pos,
                           km: pos.flatMap { p in home.map { Geo.km($0, p) } },
                           hops: h?.hops ?? c?.outPath?.hops.count, lastSeen: h?.lastHeard ?? updated ?? advert)
        }
        for c in contacts { rows[c.key.hex] = make(c.key.hex, c.name, c.type, c, heardByKey[c.key.hex]) }
        for h in heard where rows[h.key] == nil { rows[h.key] = make(h.key, h.name, NodeType(raw: UInt8(clamping: h.type)), nil, h) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = rows.values.filter { r in
            (type == nil || r.type == type) && (q.isEmpty || r.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        switch sort {
        case .heard: return list.sorted { ($0.lastSeen ?? .distantPast, $1.name) > ($1.lastSeen ?? .distantPast, $0.name) }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .distance: return list.sorted { ($0.km ?? .infinity, $0.name) < ($1.km ?? .infinity, $1.name) }
        case .hops: return list.sorted { ($0.hops ?? 99, $0.name) < ($1.hops ?? 99, $1.name) }
        }
    }
}
