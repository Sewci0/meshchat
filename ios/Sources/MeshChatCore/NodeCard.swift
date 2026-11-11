import Foundation
import MeshCoreKit

/// What the map's card says about the node you tapped, and what you can do with it: worked out here so
/// it's tested, drawn by the map.
public struct NodeCard: Equatable, Sendable {
    public struct Stat: Equatable, Sendable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Action: String, Equatable, Sendable {
        case ping, details, links, message, openRoom, route, addContact, removeContact, adminLogin
        /// ask it: a repeater's status and readings, a person's or sensor's readings
        case query
        case directions, copyID, copyPosition, changeHome, offlineMaps
    }

    /// the first bytes of its key, as repeater IDs appear in paths
    public let id: String?
    /// "Repeater · 12.4 km NE"
    public let subtitle: String
    /// "Your repeater", "Not a contact"
    public let tags: [String]
    /// "Gone quiet since 14:05": it, not the mesh, went silent
    public let quiet: String?
    public let stats: [Stat]
    public let primary: [Action]
    public let menu: [Action]

    /// - summary: its numbers from the packet log, when it has passed anything on
    /// - heard: its advert as last heard (for people and rooms: hops and signal)
    /// - directRepeaters: for home, repeaters heard straight from them in the last hour
    /// - idBytes: the radio's path hash size, so the ID reads as it does in paths
    public init(point p: MapContent.Point, summary: RepeaterAnalysis.Summary?, heard: HeardNode?, home: Position?,
                isYours: Bool, quietSince: Date?, directRepeaters: Int? = nil, now: Date = .now, idBytes: Int = 1) {
        let isHome = p.kind == .home
        id = isHome ? nil : String(p.id.prefix(max(1, idBytes) * 2)).uppercased()
        let place = home.flatMap { h -> String? in
            isHome ? nil : String(format: "%.1f km %@", Geo.km(h, p.position), Geo.bearing(h, p.position))
        }
        let kindName = switch p.kind {
        case .person: String(localized: "Person")
        case .repeater: String(localized: "Repeater")
        case .room: String(localized: "Room")
        case .sensor: String(localized: "Sensor")
        case .home: String(localized: "Your home location")
        }
        tags = (isYours ? [String(localized: "Your repeater")] : []) + (!p.isContact && !isHome ? [String(localized: "Not a contact")] : [])
        quiet = quietSince.map { String(localized: "Gone quiet since \($0.formatted(date: .omitted, time: .shortened))") }

        var stats: [Stat] = []
        func relays(_ s: RepeaterAnalysis.Summary) {
            if let d = s.lastDirect {
                stats.append(Stat(value: [Self.ago(d, now: now), s.snrMedian.map { Self.db($0) }].compactMap { $0 }.joined(separator: " · "),
                                  label: String(localized: "heard directly", comment: "Map card: the label under when a repeater was last heard straight from")))
            } else {
                stats.append(Stat(value: String(localized: "via mesh"),
                                  label: s.lastSeen == .distantPast ? String(localized: "not heard directly") : String(localized: "seen \(Self.ago(s.lastSeen, now: now))")))
            }
            stats.append(Stat(value: "\(s.activity.reduce(0, +))", label: String(localized: "passed on, 3 h", comment: "Map card: packets a repeater passed on in the last 3 hours")))
            stats.append(Stat(value: "\(s.people) · \(s.links)", label: String(localized: "people · links")))
        }
        func advert(_ h: HeardNode) {
            stats.append(Stat(value: h.hops == 0 ? String(localized: "direct") : "\(h.hops)",
                              label: h.hops == 0 ? String(localized: "heard", comment: "Map card: under \"direct\", heard straight from the node")
                                  : h.hops == 1 ? String(localized: "hop", comment: "Map card: the label under a hop count of 1")
                                  : String(localized: "hops", comment: "Map card: the label under a hop count")))
            stats.append(Stat(value: Self.db(h.snr), label: h.hops == 0 ? String(localized: "signal") : String(localized: "last-hop signal")))
            stats.append(Stat(value: Self.ago(h.lastHeard, now: now), label: String(localized: "advert heard")))
        }
        switch p.kind {
        case .repeater:
            if let s = summary { relays(s) }
        case .room:
            // a room that relays too has those numbers; otherwise its advert's
            if let s = summary { relays(s) } else if let h = heard { advert(h) }
        case .person, .sensor:
            if let h = heard { advert(h) }
        case .home:
            if let n = directRepeaters {
                stats.append(Stat(value: "\(n)", label: n == 1 ? String(localized: "repeater heard directly, 1 h") : String(localized: "repeaters heard directly, 1 h")))
            }
        }
        self.stats = stats
        // with no numbers to show, its advert is the freshest thing known
        let advert = stats.isEmpty ? p.lastHeard.map { String(localized: "advert \(Self.ago($0, now: now))") } : nil
        subtitle = ([kindName, place, isHome ? String(format: "%.5f, %.5f", p.position.latitude, p.position.longitude) : nil, advert])
            .compactMap { $0 }.joined(separator: " · ")

        let common: [Action] = [.directions, .copyID, .copyPosition]
        switch p.kind {
        case .repeater:
            primary = [.ping, .details, .links]
            menu = (p.isContact ? [.query, .adminLogin] : [.addContact]) + common + (p.isContact ? [.removeContact] : [])
        case .room:
            primary = p.isContact ? [.openRoom, .details] : [.addContact, .details]
            menu = common + (p.isContact ? [.removeContact] : [])
        case .person:
            primary = p.isContact ? [.message, .route] : [.addContact]
            menu = (p.isContact ? [.query] : []) + common + (p.isContact ? [.removeContact] : [])
        case .sensor:
            // a sensor is there for its readings
            primary = p.isContact ? [.query, .route] : [.addContact]
            menu = common + (p.isContact ? [.removeContact] : [])
        case .home:
            primary = [.changeHome, .offlineMaps]
            menu = [.copyPosition]
        }
    }

    /// "now", "4 min", "3 h", "2 d"
    public static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        return s < 60 ? String(localized: "now") : s < 3600 ? String(localized: "\(Int(s / 60)) min") : s < 86400 ? String(localized: "\(Int(s / 3600)) h")
            : String(localized: "\(Int(s / 86400)) d", comment: "Days, short")
    }

    static func db(_ v: Double) -> String { String(format: "%+.1f dB", v) }
}

/// A repeater's links to its neighbours, as lines on the map: the busiest few with a known position.
public enum MapLinks {
    public static func lines(from key: String, analysis: RepeaterAnalysis, limit: Int = 6) -> [[Position]] {
        guard let here = analysis.directory.nodes[key]?.position, let links = analysis.stats[key]?.links else { return [] }
        return links.values
            .sorted { ($0.to + $0.from, $1.key) > ($1.to + $1.from, $0.key) }
            .compactMap { l in analysis.directory.nodes[l.key]?.position.map { [here, $0] } }
            .prefix(limit)
            .map { $0 }
    }
}
