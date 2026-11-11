import Foundation
import MeshCoreKit

public enum Geo {
    /// Great-circle distance in km.
    public static func km(_ a: Position, _ b: Position) -> Double {
        let r = Double.pi / 180
        let x = pow(sin((b.latitude - a.latitude) * r / 2), 2)
            + cos(a.latitude * r) * cos(b.latitude * r) * pow(sin((b.longitude - a.longitude) * r / 2), 2)
        return 2 * 6371 * asin(sqrt(x))
    }

    // as in "12.4 km north-east"
    static let compass = [String(localized: "north"), String(localized: "north-east"), String(localized: "east"), String(localized: "south-east"),
                          String(localized: "south"), String(localized: "south-west"), String(localized: "west"), String(localized: "north-west")]

    /// Which way `b` is from `a`, as one of eight compass words.
    public static func bearing(_ a: Position, _ b: Position) -> String {
        let r = Double.pi / 180, dl = (b.longitude - a.longitude) * r
        let y = sin(dl) * cos(b.latitude * r)
        let x = cos(a.latitude * r) * sin(b.latitude * r) - sin(a.latitude * r) * cos(b.latitude * r) * cos(dl)
        let deg = (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
        return compass[Int((deg / 45).rounded()) % 8]
    }

    /// Coordinates as people paste them: "52.2297, 21.0122", "52,2297 21,0122", or a Google or Apple
    /// Maps link with them in it (as the web app reads them).
    public static func parseCoordinates(_ text: String) -> Position? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"@(-?\d+\.\d+),(-?\d+\.\d+)"#,
                        #"[?&](?:ll|q|query|center|sll)=(-?\d+\.?\d*)(?:,|%2C)\s*(-?\d+\.?\d*)"#,
                        #"^(-?\d+(?:[.,]\d+)?)\s*[,;\s]\s*(-?\d+(?:[.,]\d+)?)$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let ra = Range(m.range(at: 1), in: t), let rb = Range(m.range(at: 2), in: t),
                  let a = Double(t[ra].replacingOccurrences(of: ",", with: ".")),
                  let b = Double(t[rb].replacingOccurrences(of: ",", with: ".")) else { continue }
            return abs(a) <= 90 && abs(b) <= 180 ? Position(latitude: a, longitude: b) : nil
        }
        return nil
    }
}

/// A node that could have relayed a packet: a repeater (or room server) the radio knows or heard.
public struct KnownNode: Hashable, Sendable, Identifiable {
    public let key: String
    public var name: String
    public var type: NodeType
    public var position: Position?
    public var isContact: Bool
    public var id: String { key }

    public init(key: String, name: String, type: NodeType, position: Position?, isContact: Bool) {
        self.key = key; self.name = name; self.type = type; self.position = position; self.isContact = isContact
    }
}

/// One hop of a path, named: the node with that ID nearest the hop after it (several may share an ID).
public struct ResolvedHop: Hashable, Sendable {
    public let id: String
    public let node: KnownNode?
    /// how many candidates share the ID (more than 1: a guess)
    public let candidates: Int
    public var label: String { node.map { $0.name + (candidates > 1 ? " (?)" : "") } ?? "? \(id)" }
}

/// Names the repeater IDs in paths. Paths are 1–3 byte key prefixes; only repeaters relay (rooms when
/// no repeater matches). Among several, the one nearest the next hop toward you is taken, chaining back
/// from your home — as the web app does.
public struct NodeDirectory: Sendable {
    public let nodes: [String: KnownNode]
    public let home: Position?

    public init(contacts: [Contact], heard: [HeardNode], home: Position?) {
        var all: [String: KnownNode] = [:]
        for h in heard {
            let t = NodeType(raw: UInt8(h.type))
            let pos = h.latitude.flatMap { la in h.longitude.map { Position(latitude: la, longitude: $0) } }
            all[h.key] = KnownNode(key: h.key, name: h.name, type: t, position: pos, isContact: false)
        }
        for c in contacts {
            let prev = all[c.key.hex]
            all[c.key.hex] = KnownNode(key: c.key.hex, name: c.name, type: c.type, position: c.position ?? prev?.position, isContact: true)
        }
        nodes = all
        self.home = home
    }

    public func candidates(_ id: String) -> [KnownNode] {
        let all = nodes.values.filter { $0.key.hasPrefix(id) && ($0.type == .repeater || $0.type == .room) }
        let reps = all.filter { $0.type == .repeater }
        return (reps.isEmpty ? all : reps).sorted { $0.key < $1.key }
    }

    /// A path as received (origin first, you last), each hop named.
    public func resolve(incoming ids: [String]) -> [ResolvedHop] {
        var out = [ResolvedHop?](repeating: nil, count: ids.count)
        var near = home
        for i in stride(from: ids.count - 1, through: 0, by: -1) {
            let c = candidates(ids[i])
            let best: KnownNode?
            if let near, c.count > 1, c.contains(where: { $0.position != nil }) {
                best = c.filter { $0.position != nil }.min { Geo.km(near, $0.position!) < Geo.km(near, $1.position!) }
            } else {
                best = c.first
            }
            out[i] = ResolvedHop(id: ids[i], node: best, candidates: c.count)
            if let p = best?.position { near = p }
        }
        return out.compactMap { $0 }
    }

    /// A saved route (you first, them last): resolved from your end, the same way.
    public func resolve(outgoing ids: [String]) -> [ResolvedHop] {
        Array(resolve(incoming: ids.reversed()).reversed())
    }

    /// "39004e63" with 2-byte IDs → ["3900", "4e63"].
    public static func split(_ path: String?, hashSize: Int) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let n = max(1, hashSize) * 2
        var out: [String] = []
        var i = path.startIndex
        while i < path.endIndex {
            let j = path.index(i, offsetBy: n, limitedBy: path.endIndex) ?? path.endIndex
            out.append(String(path[i..<j]))
            i = j
        }
        return out
    }
}
