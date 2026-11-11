import Foundation
import MeshCoreKit

/// "Can I hear repeaters, and can they hear me?" — the answer to a reach check, worked out from who
/// answered (and how well, both ways) and who you've heard directly lately but stayed quiet.
public struct ReachCheck: Sendable, Equatable {
    public enum Verdict: String, Sendable { case good, marginal, weak }

    /// A repeater you've heard straight from: expected to answer.
    public struct Candidate: Sendable, Equatable {
        public let key: String
        public let name: String
        public let lastDirect: Date
        public init(key: String, name: String, lastDirect: Date) { self.key = key; self.name = name; self.lastDirect = lastDirect }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        /// the full key when known, else the prefix it answered with (two unknown answerers never share one)
        public let id: String
        /// the full key when it's known here
        public let key: String?
        public let name: String
        /// how well it heard you, and you it (nil: it didn't answer)
        public let up: Double?
        public let down: Double?
        public let verdict: Verdict?
        /// for one that stayed quiet: when you last heard it directly
        public let lastDirect: Date?
        /// it answered a ping (a one-hop trace) rather than the broadcast; or, quiet, it was pinged too
        public var byPing = false
        public var answered: Bool { up != nil }
        /// it answered, but its advert hasn't been heard here: only the start of its key is known
        public var isNew: Bool { key == nil }

        /// The same answer, now that its advert has been heard and it has a name.
        public func known(as key: String, name: String) -> Row {
            var r = Row(id: key, key: key, name: name, up: up, down: down, verdict: verdict, lastDirect: lastDirect)
            r.byPing = byPing
            return r
        }

        init(id: String? = nil, key: String?, name: String, up: Double?, down: Double?, verdict: Verdict?, lastDirect: Date?) {
            self.id = id ?? key ?? name
            self.key = key; self.name = name; self.up = up; self.down = down; self.verdict = verdict; self.lastDirect = lastDirect
        }
    }

    /// A ping's answer: how well it heard you, and you it.
    public struct PingResult: Sendable, Hashable {
        public let up: Double
        public let down: Double
    }

    /// The check as a whole, by its best answer (or, with none, why): what its symbol and colour say.
    public enum Level: Sendable, Equatable { case good, marginal, weak, hearOnly, deaf }

    /// The headline: "Olsztyn Jura RPT hears you: marginal", "3 repeaters hear you", "No repeater heard you".
    public struct Summary: Sendable, Equatable {
        public let level: Level
        public let title: String
        /// advice when nobody answered; the best one's name when several did and it's good
        public let detail: String?
    }

    public enum Diagnosis: Sendable, Equatable {
        /// repeaters heard you: the best of them
        case reachable(count: Int, best: String)
        /// you hear repeaters, but none answered
        case hearOnly
        /// nothing heard lately at all
        case deaf
    }

    public let at: Date
    public let rows: [Row]
    public let diagnosis: Diagnosis
    /// how many answered the broadcast, how many were pinged after it, and how many of those answered
    public let broadcastAnswers: Int
    public let pinged: Int
    public let pingAnswers: Int

    // what it was worked out from, to work it out again with another ping's answer
    private let answers: [DiscoveryAnswer]
    private let candidates: [Candidate]
    private let nodes: [String: String]
    private let lastHeard: Date?
    private let spreadingFactor: Int
    private let pings: [String: PingResult?]

    /// how recent "heard lately" is
    public static let recent: TimeInterval = 30 * 60
    /// wait between checks (repeaters answer at most 4 a 2 minutes, for everyone nearby)
    public static let cooldown: TimeInterval = 60

    /// - nodes: known keys and names, to name answers (which carry 8 bytes of a key)
    /// - lastHeard: when your radio last heard any packet
    /// - pings: the repeaters pinged after the broadcast (by key), and what came back (nil: no answer)
    public init(answers: [DiscoveryAnswer], candidates: [Candidate], nodes: [String: String], lastHeard: Date?,
                spreadingFactor: Int, pings: [String: (up: Double, down: Double)?] = [:], now: Date = .now) {
        self.init(answers: answers, candidates: candidates, nodes: nodes, lastHeard: lastHeard, spreadingFactor: spreadingFactor,
                  stored: pings.mapValues { $0.map { PingResult(up: $0.up, down: $0.down) } }, now: now)
    }

    private init(answers: [DiscoveryAnswer], candidates: [Candidate], nodes: [String: String], lastHeard: Date?,
                 spreadingFactor: Int, stored pings: [String: PingResult?], now: Date) {
        at = now
        self.answers = answers; self.candidates = candidates; self.nodes = nodes; self.lastHeard = lastHeard
        self.spreadingFactor = spreadingFactor; self.pings = pings
        var rows: [Row] = []
        var answeredKeys = Set<String>()
        for a in answers.sorted(by: { min($0.snrThere, $0.snrHere) > min($1.snrThere, $1.snrHere) }) {
            let prefix = a.keyPrefix.hex
            let key = nodes.keys.first { $0.hasPrefix(prefix) } ?? candidates.first { $0.key.hasPrefix(prefix) }?.key
            if let key { answeredKeys.insert(key) }
            let name = key.flatMap { k in nodes[k] ?? candidates.first { $0.key == k }?.name } ?? String(prefix.prefix(8))
            rows.append(Row(id: key ?? prefix, key: key, name: name, up: a.snrThere, down: a.snrHere,
                            verdict: Self.verdict(up: a.snrThere, down: a.snrHere, spreadingFactor: spreadingFactor), lastDirect: nil))
        }
        broadcastAnswers = rows.count
        var quiet: [Row] = []
        for c in candidates.sorted(by: { $0.lastDirect > $1.lastDirect })
        where !answeredKeys.contains(c.key) && now.timeIntervalSince(c.lastDirect) <= Self.recent {
            if let pinged = pings[c.key], let r = pinged {
                var row = Row(key: c.key, name: c.name, up: r.up, down: r.down,
                              verdict: Self.verdict(up: r.up, down: r.down, spreadingFactor: spreadingFactor), lastDirect: nil)
                row.byPing = true
                rows.append(row)
            } else {
                var row = Row(key: c.key, name: c.name, up: nil, down: nil, verdict: nil, lastDirect: c.lastDirect)
                row.byPing = pings[c.key] != nil
                quiet.append(row)
            }
        }
        // the answers best first, whichever way they came; then the quiet ones
        rows.sort { a, b in min(a.up ?? -99, a.down ?? -99) > min(b.up ?? -99, b.down ?? -99) }
        self.rows = rows + quiet
        // every ping tried counts, answered or not
        pinged = pings.count
        pingAnswers = pings.values.filter { $0 != nil }.count
        if let best = rows.first(where: \.answered) {
            diagnosis = .reachable(count: rows.filter(\.answered).count, best: best.name)
        } else if let heard = lastHeard, now.timeIntervalSince(heard) <= 15 * 60 {
            diagnosis = .hearOnly
        } else {
            diagnosis = .deaf
        }
    }

    /// The same check with one more ping's answer (nil: no answer), as of the same time: the repeater moves
    /// up among the answers, or shows it was pinged without one.
    public func adding(ping: (up: Double, down: Double)?, for key: String, spreadingFactor sf: Int? = nil) -> ReachCheck {
        var all = pings
        all.updateValue(ping.map { PingResult(up: $0.up, down: $0.down) }, forKey: key)
        return ReachCheck(answers: answers, candidates: candidates, nodes: nodes, lastHeard: lastHeard,
                          spreadingFactor: sf ?? spreadingFactor, stored: all, now: at)
    }

    /// The best answer (rows are best first).
    public var best: Row? { rows.first(where: \.answered) }

    public var level: Level {
        switch best?.verdict {
        case .good: .good
        case .marginal: .marginal
        case .weak: .weak
        case nil: diagnosis == .deaf ? .deaf : .hearOnly
        }
    }

    public var summary: Summary {
        let answered = rows.filter(\.answered)
        guard let best = answered.first, let verdict = best.verdict else {
            return level == .deaf
                ? Summary(level: .deaf, title: String(localized: "Radio hears nothing"), detail: String(localized: "Check frequency and radio settings."))
                : Summary(level: .hearOnly, title: String(localized: "No repeater heard you"), detail: String(localized: "Check antenna and power, or move higher."))
        }
        // whole sentences, one per verdict, so each translates as a whole
        if answered.count == 1 {
            let title: String
            if best.isNew {
                title = switch verdict {
                case .good: String(localized: "A new repeater (\(best.name)) hears you: good")
                case .marginal: String(localized: "A new repeater (\(best.name)) hears you: marginal")
                case .weak: String(localized: "A new repeater (\(best.name)) hears you: weak")
                }
            } else {
                let name = Self.capitalised(best.name)
                title = switch verdict {
                case .good: String(localized: "\(name) hears you: good")
                case .marginal: String(localized: "\(name) hears you: marginal")
                case .weak: String(localized: "\(name) hears you: weak")
                }
            }
            return Summary(level: level, title: title, detail: nil)
        }
        let n = answered.count
        let title = switch verdict {
        case .good: String(localized: "\(n) repeaters hear you")
        case .marginal: String(localized: "\(n) repeaters hear you: best is marginal")
        case .weak: String(localized: "\(n) repeaters hear you: best is weak")
        }
        return Summary(level: level, title: title,
                       detail: verdict == .good ? (best.isNew ? String(localized: "best: a new repeater (\(best.name))") : String(localized: "best: \(best.name)")) : nil)
    }

    private static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// How many repeaters you hear directly: those heard straight from lately (`recent`, full keys), and
    /// every one that answered this check (an answer to a zero-hop request is heard directly, and proves
    /// they hear you too). Each counted once, a new one matched by the start of its key.
    public func heardDirectly(recent: Set<String>) -> Int {
        let extra = rows.filter(\.answered).filter { r in
            if let k = r.key { return !recent.contains(k) }
            return !recent.contains { $0.hasPrefix(r.id) }
        }
        return recent.count + extra.count
    }

    /// Whom to ping after the broadcast: repeaters heard directly lately that didn't answer it, most
    /// recently heard first, at most `limit` (each ping is a moment of airtime).
    public static func pingTargets(answers: [DiscoveryAnswer], candidates: [Candidate], limit: Int = 3, now: Date = .now) -> [Candidate] {
        let answered = answers.map { $0.keyPrefix.hex }
        return candidates
            .filter { c in now.timeIntervalSince(c.lastDirect) <= recent && !answered.contains { c.key.hasPrefix($0) } }
            .sorted { $0.lastDirect > $1.lastDirect }
            .prefix(limit)
            .map { $0 }
    }

    /// The decode floor: the lowest SNR LoRa still decodes at this spreading factor (−5 dB at SF6, −7.5
    /// at SF7, … −20 at SF12).
    public static func floor(spreadingFactor sf: Int) -> Double { -2.5 * Double(sf - 4) }

    /// Judged by the weaker direction: 10 dB or more above the floor is good, 5 marginal, less weak.
    public static func verdict(up: Double, down: Double, spreadingFactor sf: Int) -> Verdict {
        let margin = min(up, down) - floor(spreadingFactor: sf)
        return margin >= 10 ? .good : margin >= 5 ? .marginal : .weak
    }

    /// Seconds before another check is fair, after one at `last`.
    public static func wait(after last: Date?, now: Date = .now) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(last))
    }
}

extension ReachCheck.Verdict: Comparable {
    private var rank: Int {
        switch self {
        case .weak: 0
        case .marginal: 1
        case .good: 2
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// How recently a repeater was heard directly, for the badge on its row.
public enum Freshness: Sendable, Equatable {
    /// under 5 minutes
    case live
    /// under 30 minutes
    case recent
    /// longer ago
    case stale
    /// only ever seen in paths, never heard directly
    case never

    public init(lastDirect: Date?, now: Date = .now) {
        guard let d = lastDirect else { self = .never; return }
        let age = now.timeIntervalSince(d)
        self = age < 5 * 60 ? .live : age < 30 * 60 ? .recent : .stale
    }
}
