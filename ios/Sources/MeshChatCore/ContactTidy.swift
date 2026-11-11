import Foundation
import MeshCoreKit

/// Tidying the radio's contact list (it holds a few hundred, and on a busy mesh fills with repeaters):
/// which contacts to remove, the kinds you pick that haven't been heard for a while, and which always
/// stay. Only the radio forgets them: the app keeps what it heard, so they stay in Nodes and on the map.
public struct ContactTidy: Sendable, Equatable {
    /// How long since it was last heard, for it to go.
    public enum Age: Int, CaseIterable, Sendable {
        case week = 7, month = 30
        /// however recently
        case any = 0

        public var label: String {
            switch self {
            case .week: String(localized: "Over a week ago")
            case .month: String(localized: "Over a month ago")
            case .any: String(localized: "Any time")
            }
        }
    }

    public struct Options: Sendable, Equatable {
        public var kinds: Set<NodeType>
        public var age: Age
        /// only those heard more than this many hops away (nil: any distance)
        public var beyondHops: Int?
        public init(kinds: Set<NodeType>, age: Age, beyondHops: Int? = nil) { self.kinds = kinds; self.age = age; self.beyondHops = beyondHops }
        /// repeaters and sensors more than 3 hops away: on a busy mesh they pile up, all heard lately (they
        /// advertise every few hours), and messages to people near you never need them as contacts
        public static let standard = Options(kinds: [.repeater, .sensor], age: .any, beyondHops: 3)
        /// the distances offered
        public static let hopChoices: [Int?] = [nil, 1, 2, 3, 5]
    }

    /// Why a contact stays, first reason that applies.
    public enum Keep: Int, CaseIterable, Sendable, Comparable {
        /// not one of the kinds being tidied
        case otherKind
        case favourite
        /// a room you've joined and not left
        case joinedRoom
        /// you have messages with it
        case messaged
        /// the repeater you hear most directly
        case yourRepeater
        case heardLately
        /// within the hops chosen
        case near
        /// how far isn't known (not heard here since the app's history began, and no route)
        case distanceUnknown

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// To remove, the longest unheard first (so a tidy stopped halfway has removed the right ones).
    public let remove: [Contact]
    public let kept: [Keep: Int]
    public let total: Int

    /// - lastHeard: when the app last heard each node (by key hex)
    /// - hops: how far each node is, in hops (its last advert's path, else its route)
    /// - messaged: keys (hex) of contacts you have messages with
    /// - joinedRooms: keys (hex) of rooms you've joined and not left
    public init(contacts: [Contact], lastHeard: [String: Date], hops: [String: Int] = [:], messaged: Set<String>,
                joinedRooms: Set<String>, yourRepeater: String?, options: Options, now: Date = .now) {
        // (seconds compared, never `Date < Date`: the iOS 27.2 SDK calls a Foundation function for that
        // which 27.2 betas lack, and crash)
        let cutoff = now.timeIntervalSince1970 - Double(options.age.rawValue) * 86400
        var remove: [(Contact, Double)] = []
        var kept: [Keep: Int] = [:]
        /// kept for its distance: near enough, or not known
        func distance(_ h: Int?) -> Keep? {
            guard let n = options.beyondHops else { return nil }
            guard let h else { return .distanceUnknown }
            return h <= n ? .near : nil
        }
        for c in contacts {
            let key = c.key.hex
            let heard = Self.lastHeard(c, app: lastHeard[key], now: now).timeIntervalSince1970
            let keep: Keep? =
                !options.kinds.contains(c.type) ? .otherKind
                : c.isFavourite ? .favourite
                : joinedRooms.contains(key) ? .joinedRoom
                : messaged.contains(key) ? .messaged
                : key == yourRepeater ? .yourRepeater
                : options.age != .any && heard > cutoff ? .heardLately
                : distance(hops[key])
            if let keep { kept[keep, default: 0] += 1 } else { remove.append((c, heard)) }
        }
        self.remove = remove.sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }.map(\.0)
        self.kept = kept
        total = contacts.count
    }

    public var keptCount: Int { total - remove.count }

    /// What the button says: "Remove 287 repeaters", "Remove 12 contacts", "Nothing to remove".
    public var actionTitle: String {
        if remove.isEmpty { return String(localized: "Nothing to remove") }
        let kinds = Set(remove.map(\.type))
        let n = remove.count
        // each title whole, so it translates (and takes its plural) as one
        if kinds.count == 1, let k = kinds.first {
            return switch k {
            case .repeater: n == 1 ? String(localized: "Remove 1 repeater") : String(localized: "Remove \(n) repeaters")
            case .sensor: n == 1 ? String(localized: "Remove 1 sensor") : String(localized: "Remove \(n) sensors")
            case .room: n == 1 ? String(localized: "Remove 1 room") : String(localized: "Remove \(n) rooms")
            case .companion: n == 1 ? String(localized: "Remove 1 person") : String(localized: "Remove \(n) people")
            case .unknown: n == 1 ? String(localized: "Remove 1 contact") : String(localized: "Remove \(n) contacts")
            }
        }
        return n == 1 ? String(localized: "Remove 1 contact") : String(localized: "Remove \(n) contacts")
    }

    /// When a contact was last heard: by the app, or when the radio last updated it (it does on each of its
    /// adverts, by its own clock, which the app keeps set), or its own advert time unless that's in the
    /// future (a node with a wrong clock). Never heard: the distant past.
    public static func lastHeard(_ c: Contact, app: Date?, now: Date = .now) -> Date {
        let modified = c.lastModified > 0 ? Date(timeIntervalSince1970: Double(c.lastModified)) : nil
        let advert = c.lastAdvert > 0 ? Date(timeIntervalSince1970: Double(c.lastAdvert)) : nil
        let times = [app, modified, advert].compactMap { $0?.timeIntervalSince1970 }.filter { $0 - now.timeIntervalSince1970 <= 300 }
        return times.max().map { Date(timeIntervalSince1970: $0) } ?? .distantPast
    }

    /// Clearing the list: every contact (or all but favourites), whatever its kind and whoever it is,
    /// longest unheard first.
    public static func everything(_ contacts: [Contact], lastHeard: [String: Date], keepFavourites: Bool, now: Date = .now) -> [Contact] {
        contacts.filter { !(keepFavourites && $0.isFavourite) }
            .map { ($0, Self.lastHeard($0, app: lastHeard[$0.key.hex], now: now).timeIntervalSince1970) }
            .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
            .map(\.0)
    }

    /// How full the radio's contact list is: "344 of 350", and whether it's nearly full (90% or more).
    public static func fullness(count: Int, max: Int) -> (text: String, nearlyFull: Bool) {
        (String(localized: "\(count) of \(max)"), max > 0 && Double(count) >= Double(max) * 0.9)
    }
}

extension AutoAddConfig {
    /// How far new nodes are added from, in hops (nil: any distance). The radio's number is one more: 0 no
    /// limit, 1 heard directly, N up to N−1 hops.
    public var reachHops: Int? { maxHops == 0 ? nil : maxHops - 1 }

    public var reachText: String {
        switch reachHops {
        case nil: String(localized: "Any distance")
        case 0?: String(localized: "Direct only")
        case 1?: String(localized: "Up to 1 hop")
        case let n?: String(localized: "Up to \(n) hops")
        }
    }

    /// The radio's number for "up to `hops` hops away".
    public static func maxHops(forReach hops: Int) -> Int { min(64, max(0, hops) + 1) }
}
