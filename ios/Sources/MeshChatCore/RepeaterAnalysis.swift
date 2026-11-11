import Foundation
import MeshCoreKit

/// What the repeaters around you do, worked out from the packets your radio heard — the web app's
/// lib/repeaters.ts and the Mac server's RepeaterIndex, in Swift; keep the three in step.
///
/// Repeaters keep no list of users, but every packet carries the IDs of the repeaters it passed. The
/// first is where the sender entered the mesh, so adverts and channel messages tell who uses which
/// repeater; neighbouring IDs in a path are repeaters that hear each other.
public struct RepeaterAnalysis: Sendable {
    public struct User: Hashable, Sendable, Identifiable {
        public var key: String?
        public var name: String?
        public var type: String
        public var count: Int
        public var lastSeen: Date
        /// every sighting went through an ID several repeaters share
        public var uncertain: Bool
        /// "advert", "channel"
        public var via: Set<String>
        public var id: String { key ?? "name:\(name ?? "")" }
    }

    public struct SignalPoint: Hashable, Sendable {
        public let date: Date
        public let snr: Double
        public let rssi: Int
        public let type: String
    }

    public struct Recent: Hashable, Sendable {
        public let date: Date
        public let type: String
        public let hops: Int
        /// its place in the path (1 = where the sender entered the mesh)
        public let position: Int
        public let snr: Double?
        public let what: String?
    }

    public struct Link: Hashable, Sendable, Identifiable {
        public let key: String
        public var to: Int
        public var from: Int
        public var id: String { key }
    }

    public struct Stats: Sendable {
        public var relayed = 0, firstHop = 0, lastHop = 0, uncertain = 0
        public var lastSeen = Date.distantPast
        public var snr: [Double] = []
        public var people: [String: User] = [:]
        public var nodes: [String: User] = [:]
        public var links: [String: Link] = [:]
        /// packets passed on per 10 minutes, the last 3 hours (oldest first)
        public var activity = [Int](repeating: 0, count: RepeaterAnalysis.activityBuckets)
        public var recent: [Recent] = []
        public var signal: [SignalPoint] = []
        /// how many of your messages entered the mesh through it (it passed them on first, so it hears you),
        /// and the last time
        public var heardYou = 0
        public var heardYouLast = Date.distantPast
        /// the newest packet heard straight from it
        public var lastDirect = Date.distantPast
        public init() {}
    }

    public struct Summary: Hashable, Sendable, Identifiable {
        public let key: String
        public let name: String
        public let type: NodeType
        public let isContact: Bool
        public let position: Position?
        public let km: Double?
        public let relayed: Int, firstHop: Int, lastHop: Int
        public let uncertainShare: Double
        /// heard straight from it
        public let direct: Bool
        public let snrMedian: Double?
        public let people: Int, nodes: Int, links: Int
        public let lastSeen: Date
        /// heard straight from it (not just in paths), if ever
        public let lastDirect: Date?
        /// packets passed on per 10 minutes, the last 3 hours (oldest first)
        public let activity: [Int]
        public var id: String { key }
    }

    /// A repeater you heard straight from regularly, silent for a while though enough else arrived that
    /// some of it should have been its own: it, not the mesh, went quiet.
    public struct Quiet: Hashable, Sendable {
        public let since: Date
        public let missed: Int
        public let expected: Int
        /// the repeater reaching you best now
        public let next: (key: String, name: String, snr: Double, position: Position?)?

        public static func == (a: Quiet, b: Quiet) -> Bool { a.since == b.since && a.missed == b.missed && a.next?.key == b.next?.key }
        public func hash(into h: inout Hasher) { h.combine(since); h.combine(missed) }
    }

    /// The activity chart: 10-minute steps over the last 3 hours, counted back from now.
    public static let activityBucket: TimeInterval = 600, activityBuckets = 18

    public static let quietAfter: TimeInterval = 15 * 60, quietMinHeard = 10, quietExpected = 8.0, quietNext: TimeInterval = 30 * 60

    public let stats: [String: Stats]
    public let directory: NodeDirectory
    /// the days of the log looked at
    public let days: Int
    /// hops whose ID no known repeater has
    public let unknownHops: Int
    public let packetsCounted: Int
    public let oldest: Date?
    private let times: [Date]

    /// - Parameters:
    ///   - packets: the packet log, any order
    ///   - channelRoutes: channel messages with a path: who sent them (nil for yours) and the path
    public init(packets: [PacketRecord], channelRoutes: [(sender: String?, path: String, hashSize: Int, date: Date)],
                directory: NodeDirectory, days: Int = 7, now: Date = .now) {
        self.directory = directory
        self.days = days
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var stats: [String: Stats] = [:]
        var unknown = 0, counted = 0
        var oldest: Date?
        var times: [Date] = []
        var cache: [String: [KnownNode]] = [:]
        var carried = Set<String>()
        let contactKeys = directory.nodes.values.filter(\.isContact).map(\.key)

        func resolve(_ ids: [String]) -> [(key: String, uncertain: Bool)?] {
            var out = [(key: String, uncertain: Bool)?](repeating: nil, count: ids.count)
            var near = directory.home
            for i in stride(from: ids.count - 1, through: 0, by: -1) {
                let c = cache[ids[i]] ?? directory.candidates(ids[i])
                cache[ids[i]] = c
                guard !c.isEmpty else { continue }
                let located = c.filter { $0.position != nil }
                let best = c.count == 1 || located.isEmpty || near == nil ? c[0]
                    : located.min { Geo.km(near!, $0.position!) < Geo.km(near!, $1.position!) }!
                out[i] = (best.key, c.count > 1)
                if let p = best.position { near = p }
            }
            return out
        }
        func repByPrefix(_ p: String) -> String? { directory.nodes.values.first { $0.key.hasPrefix(p) && ($0.type == .repeater || $0.type == .room) }?.key }
        func heardDirect(_ key: String, _ p: PacketRecord) {
            stats[key, default: Stats()].lastHop += 1
            stats[key]!.lastDirect = max(stats[key]!.lastDirect, p.date)
            stats[key]!.snr.append(p.snr)
            stats[key]!.signal.append(SignalPoint(date: p.date, snr: p.snr, rssi: p.rssi, type: p.type))
        }
        func link(_ a: String, _ b: String) {
            stats[a, default: Stats()].links[b, default: Link(key: b, to: 0, from: 0)].to += 1
            stats[b, default: Stats()].links[a, default: Link(key: a, to: 0, from: 0)].from += 1
        }
        func user(_ key: String, id: String?, name: String?, type: String?, date: Date, uncertain: Bool, via: String) {
            let isPerson = type == nil || type == "companion"
            let uid = id ?? "name:\(name ?? "")"
            var e = (isPerson ? stats[key]?.people[uid] : stats[key]?.nodes[uid])
                ?? User(key: id, name: name, type: type ?? "companion", count: 0, lastSeen: .distantPast, uncertain: true, via: [])
            e.count += 1; e.lastSeen = max(e.lastSeen, date); e.uncertain = e.uncertain && uncertain; e.via.insert(via)
            if let name, !name.isEmpty { e.name = name }
            if isPerson { stats[key, default: Stats()].people[uid] = e } else { stats[key, default: Stats()].nodes[uid] = e }
        }

        for p in packets.sorted(by: { ($0.date, $0.id ?? 0) < ($1.date, $1.id ?? 0) }) where p.date > since {
            counted += 1
            times.append(p.date)
            oldest = oldest.map { min($0, p.date) } ?? p.date
            let packet = MeshPacket(raw: p.raw)
            let advert = packet?.advert
            let ids = NodeDirectory.split(p.path, hashSize: p.hashSize)
            if ids.isEmpty {
                // a repeater's own advert heard straight from it: you hear that repeater directly
                if let a = advert, a.type == .repeater, let k = repByPrefix(a.key.hex) {
                    stats[k, default: Stats()].lastSeen = max(stats[k]?.lastSeen ?? .distantPast, p.date)
                    heardDirect(k, p)
                }
                continue
            }
            let res = resolve(ids)
            for (i, hop) in res.enumerated() {
                guard let hop else { unknown += 1; continue }
                // a packet heard several times, along different paths, is one packet: each repeater passed it
                // on once, and it entered the mesh once (copies share the fingerprint; 0: not known)
                func once(_ what: String) -> Bool { p.fingerprint == 0 || carried.insert("\(what)|\(p.fingerprint)|\(hop.key)").inserted }
                var s = stats[hop.key] ?? Stats()
                s.lastSeen = max(s.lastSeen, p.date)
                let fresh = once("r")
                if fresh {
                    s.relayed += 1
                    s.uncertain += hop.uncertain ? 1 : 0
                    let step = Int((now.timeIntervalSince(p.date) / Self.activityBucket).rounded(.down))
                    if (0..<Self.activityBuckets).contains(step) { s.activity[Self.activityBuckets - 1 - step] += 1 }
                }
                stats[hop.key] = s
                if i + 1 < res.count, let next = res[i + 1], next.key != hop.key, once("l>" + next.key) { link(hop.key, next.key) }
                if i == res.count - 1 { heardDirect(hop.key, p) }   // the copy you heard came from this one
                if i == 0, once("f") {
                    stats[hop.key]!.firstHop += 1
                    if let a = advert {
                        if a.type == .repeater {
                            if let own = repByPrefix(a.key.hex), own != hop.key { link(own, hop.key) }
                        } else {
                            let full = contactKeys.first { $0.hasPrefix(a.key.hex) } ?? a.key.hex
                            user(hop.key, id: full, name: a.name, type: "\(a.type)", date: p.date, uncertain: hop.uncertain, via: "advert")
                        }
                    }
                }
                guard fresh else { continue }
                if stats[hop.key]!.recent.count >= 15 { stats[hop.key]!.recent.removeFirst() }
                stats[hop.key]!.recent.append(Recent(date: p.date, type: p.type, hops: p.hops, position: i + 1,
                                                     snr: i == res.count - 1 ? p.snr : nil, what: advert?.name))
            }
        }

        // channel messages name their sender: who sent through which repeater; for yours, the first
        // repeater passing it on heard you directly
        for r in channelRoutes where r.date > since {
            let ids = NodeDirectory.split(r.path, hashSize: r.hashSize)
            guard let first = resolve(ids).first, let first else { continue }
            if let sender = r.sender {
                user(first.key, id: nil, name: sender, type: nil, date: r.date, uncertain: first.uncertain, via: "channel")
            } else {
                stats[first.key, default: Stats()].heardYou += 1
                stats[first.key]!.heardYouLast = max(stats[first.key]!.heardYouLast, r.date)
            }
        }

        // a sender seen by name in channels and by key in adverts is one person
        for (k, var s) in stats {
            for (nk, e) in s.people where nk.hasPrefix("name:") {
                guard let twin = s.people.first(where: { !$0.key.hasPrefix("name:") && $0.value.name == e.name })?.key else { continue }
                s.people[twin]!.count += e.count
                s.people[twin]!.lastSeen = max(s.people[twin]!.lastSeen, e.lastSeen)
                s.people[twin]!.via.formUnion(e.via)
                s.people[twin]!.uncertain = s.people[twin]!.uncertain && e.uncertain
                s.people[nk] = nil
            }
            stats[k] = s
        }
        self.stats = stats
        unknownHops = unknown
        packetsCounted = counted
        self.oldest = oldest
        self.times = times
    }

    public func summary(_ key: String) -> Summary {
        let s = stats[key] ?? Stats()
        let n = directory.nodes[key]
        let snr = s.snr.sorted()
        return Summary(key: key, name: n?.name ?? String(key.prefix(8)), type: n?.type ?? .repeater, isContact: n?.isContact ?? false,
                       position: n?.position, km: n?.position.flatMap { p in directory.home.map { (Geo.km($0, p) * 10).rounded() / 10 } },
                       relayed: s.relayed, firstHop: s.firstHop, lastHop: s.lastHop,
                       uncertainShare: s.relayed > 0 ? Double(s.uncertain) / Double(s.relayed) : 0,
                       direct: s.lastHop > 0, snrMedian: snr.isEmpty ? nil : snr[snr.count / 2],
                       people: s.people.count, nodes: s.nodes.count, links: s.links.count, lastSeen: s.lastSeen,
                       lastDirect: s.lastDirect == .distantPast ? nil : s.lastDirect, activity: s.activity)
    }

    /// Every repeater that carried something, busiest first.
    public var list: [Summary] {
        stats.keys.map(summary).sorted { ($0.relayed, $1.name) > ($1.relayed, $0.name) }
    }

    /// "Your" repeater: the one that most often passed on your messages first, so it hears you. Only that:
    /// with none of your messages seen passing through a repeater, none is yours (the one heard most
    /// isn't the same claim).
    public var yours: (key: String, passesYours: Bool, passed: Int)? {
        guard let best = stats.filter({ $0.value.heardYou > 0 })
            .max(by: { ($0.value.heardYou, $0.value.heardYouLast) < ($1.value.heardYou, $1.value.heardYouLast) }) else { return nil }
        return (best.key, true, best.value.heardYou)
    }

    public func quiet(_ key: String, now: Date = .now) -> Quiet? {
        guard let s = stats[key], s.lastHop >= Self.quietMinHeard, now.timeIntervalSince(s.lastDirect) >= Self.quietAfter else { return nil }
        var before = 0, after = 0
        for t in times { if t > s.lastDirect { after += 1 } else { before += 1 } }
        let expected = before > 0 ? Double(s.lastHop) / Double(before) * Double(after) : 0
        guard expected >= Self.quietExpected else { return nil }
        let from = max(s.lastDirect, now.addingTimeInterval(-Self.quietNext))
        var next: (key: String, name: String, snr: Double, position: Position?)?
        for (k, o) in stats where k != key {
            let snr = o.signal.filter { $0.date > from }.map(\.snr).sorted()
            guard snr.count >= 3 else { continue }
            let med = snr[snr.count / 2]
            if next == nil || med > next!.snr {
                let n = directory.nodes[k]
                next = (k, n?.name ?? String(k.prefix(8)), med, n?.position)
            }
        }
        return Quiet(since: s.lastDirect, missed: after, expected: Int(expected.rounded()), next: next)
    }
}
