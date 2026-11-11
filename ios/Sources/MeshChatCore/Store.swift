import Foundation
import GRDB
import MeshCoreKit

/// The app's history on the phone: messages, the packet log, heard nodes, route histories, rooms, the
/// latest answers from repeaters and rooms, and listened channels. SQLite (GRDB), in Application Support,
/// excluded from iCloud backup only for the packet log's size: messages are backed up.
public final class Store: Sendable {
    public let db: DatabaseWriter

    /// The app's database file.
    public static func onDisk() throws -> Store {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var config = Configuration()
        config.label = "MeshChat"
        return try Store(DatabasePool(path: dir.appendingPathComponent("meshchat.sqlite").path, configuration: config))
    }

    /// For tests and previews.
    public static func inMemory() throws -> Store { try Store(DatabaseQueue()) }

    init(_ db: DatabaseWriter) throws {
        self.db = db
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .datetime).notNull()
                t.column("senderTimestamp", .integer)
                t.column("conversation", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("sender", .text)
                t.column("text", .text).notNull()
                t.column("hops", .integer)
                t.column("path", .text)
                t.column("hashSize", .integer).notNull().defaults(to: 1)
                t.column("snr", .double)
                t.column("rssi", .integer)
                t.column("status", .text).notNull()
                t.column("repeats", .integer).notNull().defaults(to: 0)
                t.column("attempts", .integer).notNull().defaults(to: 1)
                t.column("triesFlood", .text)
                t.column("ackTry", .integer)
                t.column("roundTripMs", .integer)
                t.column("author", .text)
                t.column("fingerprint", .integer)
                t.column("network", .text)
            }
            try db.create(index: "message_conversation", on: "message", columns: ["conversation", "id"])
            try db.create(index: "message_fingerprint", on: "message", columns: ["fingerprint"])
            try db.create(table: "packet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .datetime).notNull()
                t.column("route", .text).notNull()
                t.column("type", .text).notNull()
                t.column("hops", .integer).notNull()
                t.column("path", .text).notNull()
                t.column("hashSize", .integer).notNull()
                t.column("snr", .double).notNull()
                t.column("rssi", .integer).notNull()
                t.column("fingerprint", .integer).notNull()
                t.column("raw", .blob).notNull()
                t.column("channelHash", .integer)
                t.column("network", .text)
            }
            try db.create(index: "packet_fingerprint", on: "packet", columns: ["fingerprint"])
            try db.create(index: "packet_date", on: "packet", columns: ["date"])
            try db.create(table: "heard") { t in
                t.primaryKey("key", .text)
                t.column("name", .text).notNull()
                t.column("type", .integer).notNull()
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("firstHeard", .datetime).notNull()
                t.column("lastHeard", .datetime).notNull()
                t.column("snr", .double).notNull()
                t.column("rssi", .integer).notNull()
                t.column("hops", .integer).notNull()
                t.column("path", .text).notNull()
                t.column("hashSize", .integer).notNull()
                t.column("count", .integer).notNull()
                t.column("network", .text)
            }
            for table in ["route", "room", "live"] {
                // small per-node records, kept whole
                try db.create(table: table) { t in
                    t.primaryKey("key", .text)
                    switch table {
                    case "route":
                        for c in ["current", "previous", "resetBy"] { t.column(c, .text) }
                        for c in ["learned", "confirmed", "previousSince", "reset"] { t.column(c, .datetime) }
                        t.column("learns", .integer).notNull(); t.column("changes", .integer).notNull()
                        t.column("viaPacket", .integer); t.column("viaSNR", .double); t.column("viaRSSI", .integer); t.column("viaHops", .integer)
                    case "room":
                        for c in ["joined", "loginAt", "leftAt"] { t.column(c, .datetime) }
                        t.column("left", .boolean).notNull(); t.column("role", .text); t.column("admin", .boolean).notNull()
                    default:
                        t.column("date", .datetime).notNull(); t.column("ok", .boolean).notNull(); t.column("error", .text)
                        t.column("role", .text); t.column("admin", .boolean).notNull(); t.column("serverTime", .integer)
                        t.column("firmwareLevel", .integer); t.column("status", .blob); t.column("neighbours", .text)
                        t.column("neighboursTotal", .integer)
                    }
                }
            }
            try db.create(table: "listened") { t in
                t.primaryKey("name", .text)
                t.column("added", .datetime).notNull()
            }
        }
        m.registerMigration("roomPostAuthors") { db in _ = try repairRoomPosts(db) }
        m.registerMigration("telemetry") { db in
            // a node's readings as last asked for
            try db.create(table: "telemetry") { t in
                t.primaryKey("key", .text)
                t.column("date", .datetime).notNull()
                t.column("data", .blob)
                t.column("error", .text)
            }
        }
        m.registerMigration("heardPerNetwork") { db in
            // a record per node and network (it was per node, moved to whichever network it was heard on last)
            try db.create(table: "heardNew") { t in
                t.column("key", .text).notNull()
                t.column("name", .text).notNull()
                t.column("type", .integer).notNull()
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("firstHeard", .datetime).notNull()
                t.column("lastHeard", .datetime).notNull()
                t.column("snr", .double).notNull()
                t.column("rssi", .integer).notNull()
                t.column("hops", .integer).notNull()
                t.column("path", .text).notNull()
                t.column("hashSize", .integer).notNull()
                t.column("count", .integer).notNull()
                t.column("network", .text).notNull().defaults(to: "")
                t.primaryKey(["key", "network"])
            }
            try db.execute(sql: """
                INSERT INTO heardNew SELECT key, name, type, latitude, longitude, firstHeard, lastHeard, snr, rssi, hops, path,
                    hashSize, count, COALESCE(network, '') FROM heard
                """)
            try db.drop(table: "heard")
            try db.rename(table: "heardNew", to: "heard")
        }
        return m
    }

    /// Room posts received before the text type was read right have their author's key prefix at the
    /// front of the text (see RoomPostRepair): takes it off posts from rooms joined here or heard
    /// advertising, and names a partly known author by their key prefix, as unknown authors show.
    /// Returns how many it repaired. Only once, as a migration: run again, it would cut 4 more bytes
    /// off posts it already repaired (posts received since carry their author and aren't touched).
    static func repairRoomPosts(_ db: Database) throws -> Int {
        let rooms = try String.fetchAll(db, sql: "SELECT key FROM room UNION SELECT key FROM heard WHERE type = ?",
                                        arguments: [Int(NodeType.room.rawValue)])
        var repaired = 0
        for key in rooms {
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM message WHERE conversation = ? AND direction = ? AND author IS NULL",
                                        arguments: ["dm:\(key.lowercased())", Direction.incoming.rawValue])
            for row in rows {
                let id: Int64 = row["id"], text: String = row["text"]
                guard let fixed = RoomPostRepair.split(text) else { continue }
                if let author = fixed.author {
                    try db.execute(sql: "UPDATE message SET text = ?, sender = ? WHERE id = ?", arguments: [fixed.text, author, id])
                } else {
                    try db.execute(sql: "UPDATE message SET text = ? WHERE id = ?", arguments: [fixed.text, id])
                }
                repaired += 1
            }
        }
        return repaired
    }

    /// For tests: a database as an earlier version left it (migrated up to `migration`, then `sql` run in
    /// it), opened now.
    static func upgraded(from migration: String, after sql: [String]) throws -> Store {
        let q = try DatabaseQueue()
        try migrator.migrate(q, upTo: migration)
        try q.write { db in for s in sql { try db.execute(sql: s) } }
        return try Store(q)
    }

    /// For tests: runs the room post repair again.
    func repairRoomPosts() throws -> Int { try db.write { db in try Self.repairRoomPosts(db) } }

    // MARK: messages

    @discardableResult
    public func insert(_ m: Message) throws -> Message {
        try db.write { db in try m.inserted(db) }
    }

    public func update(_ m: Message) throws { try db.write { db in try m.update(db) } }

    public func message(_ id: Int64) throws -> Message? { try db.read { db in try Message.fetchOne(db, key: id) } }

    /// A conversation's newest `limit` messages, oldest first.
    public func messages(in c: ConversationID, limit: Int = 500) throws -> [Message] {
        try db.read { db in
            try Message.filter(Column("conversation") == c.description).order(Column("id").desc).limit(limit).fetchAll(db).reversed()
        }
    }

    /// Already recorded? (Another app may have fetched the same message from the radio's queue.)
    public func hasIncoming(_ c: ConversationID, senderTimestamp: UInt32, text: String) throws -> Bool {
        try db.read { db in
            try Message.filter(Column("conversation") == c.description && Column("senderTimestamp") == senderTimestamp
                               && Column("text") == text && Column("direction") == Direction.incoming.rawValue).fetchCount(db) > 0
        }
    }

    /// Our recent messages still waiting for something (an echo, an ACK).
    public func outgoing(_ c: ConversationID? = nil, since: Date) throws -> [Message] {
        try db.read { db in
            var q = Message.filter(Column("direction") == Direction.outgoing.rawValue && Column("date") > since)
            if let c { q = q.filter(Column("conversation") == c.description) }
            return try q.order(Column("id").desc).fetchAll(db)
        }
    }

    public func conversations() throws -> [ConversationSummary] {
        try db.read { db in
            try ConversationSummary.fetchAll(db, sql: """
                SELECT conversation, MAX(id) AS lastID, COUNT(*) AS count, MAX(date) AS lastDate FROM message GROUP BY conversation
                """)
        }
    }

    public func deleteMessage(_ id: Int64) throws { _ = try db.write { db in try Message.deleteOne(db, key: id) } }

    public func deleteConversation(_ c: ConversationID) throws -> Int {
        try db.write { db in try Message.filter(Column("conversation") == c.description).deleteAll(db) }
    }

    // MARK: packets

    @discardableResult
    public func insert(_ p: PacketRecord) throws -> PacketRecord {
        try db.write { db in
            let saved = try p.inserted(db)
            // keep the newest 100,000 (about a week of a busy mesh)
            if let id = saved.id, id % 1000 == 0 { try db.execute(sql: "DELETE FROM packet WHERE id < ?", arguments: [id - 100_000]) }
            return saved
        }
    }

    /// - network: only those heard on it, and those from before networks were kept (nil: on any)
    public func recentPackets(type: String? = nil, since: Date, network: String? = nil) throws -> [PacketRecord] {
        try db.read { db in
            var q = PacketRecord.filter(Column("date") > since)
            if let type { q = q.filter(Column("type") == type) }
            if let network { q = q.filter(Column("network") == network || Column("network") == nil) }
            return try q.order(Column("id").desc).fetchAll(db)
        }
    }

    /// The newest `limit` packets (on `network`, as above).
    public func packets(limit: Int = 300, network: String? = nil) throws -> [PacketRecord] {
        try db.read { db in
            var q = PacketRecord.all()
            if let network { q = q.filter(Column("network") == network || Column("network") == nil) }
            return try q.order(Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    /// Every copy heard of one packet, in the order heard.
    public func copies(of fingerprint: Int64) throws -> [PacketRecord] {
        try db.read { db in try PacketRecord.filter(Column("fingerprint") == fingerprint).order(Column("id")).fetchAll(db) }
    }

    public func isFingerprintLinked(_ fp: Int64) throws -> Bool {
        try db.read { db in try Message.filter(Column("fingerprint") == fp).fetchCount(db) > 0 }
    }

    /// Channel messages with a route, for the repeater analysis: the sender (nil for yours, which a
    /// repeater was heard passing on) and the path.
    public func channelRoutes(since: Date, network: String? = nil) throws -> [(sender: String?, path: String, hashSize: Int, date: Date)] {
        try db.read { db in
            var q = Message.filter(Column("date") > since && Column("conversation").like("chan:%") && Column("path") != nil && Column("path") != "")
            if let network { q = q.filter(Column("network") == network || Column("network") == nil) }
            return try q.fetchAll(db)
                .map { (sender: $0.direction == .incoming ? $0.sender : nil, path: $0.path ?? "", hashSize: $0.hashSize, date: $0.date) }
        }
    }

    // MARK: small records

    public func save<R: PersistableRecord & Sendable>(_ r: R) throws { try db.write { db in try r.save(db) } }

    /// Nodes heard on `network`, and before networks were kept, one each (the newer where both); nil: on
    /// any network, one each.
    public func heard(network: String? = nil) throws -> [HeardNode] {
        try db.read { db in
            var q = HeardNode.all()
            if let network { q = q.filter(Column("network") == network || Column("network") == "") }
            return HeardNode.newestPerNode(try q.fetchAll(db))
        }
    }
    /// Every record: a node heard on two networks twice.
    public func heardEverywhere() throws -> [HeardNode] { try db.read { db in try HeardNode.fetchAll(db) } }
    /// A node as heard on one network ("": before networks were kept).
    public func heardNode(_ key: String, network: String) throws -> HeardNode? {
        try db.read { db in try HeardNode.fetchOne(db, key: ["key": key, "network": network]) }
    }
    /// A node as last heard, on whichever network.
    public func heardNode(_ key: String) throws -> HeardNode? {
        try db.read { db in try HeardNode.filter(Column("key") == key).order(Column("lastHeard").desc).fetchOne(db) }
    }
    public func route(_ key: String) throws -> RouteHistory? { try db.read { db in try RouteHistory.fetchOne(db, key: key) } }
    public func routes() throws -> [RouteHistory] { try db.read { db in try RouteHistory.fetchAll(db) } }
    public func room(_ key: String) throws -> RoomMembership? { try db.read { db in try RoomMembership.fetchOne(db, key: key) } }
    public func rooms() throws -> [RoomMembership] { try db.read { db in try RoomMembership.fetchAll(db) } }
    public func liveAnswer(_ key: String) throws -> LiveAnswer? { try db.read { db in try LiveAnswer.fetchOne(db, key: key) } }
    public func telemetryAnswer(_ key: String) throws -> TelemetryAnswer? { try db.read { db in try TelemetryAnswer.fetchOne(db, key: key) } }
    public func listened() throws -> [ListenedChannel] { try db.read { db in try ListenedChannel.order(Column("added")).fetchAll(db) } }
    public func removeListened(_ name: String) throws { _ = try db.write { db in try ListenedChannel.deleteOne(db, key: name) } }
}
