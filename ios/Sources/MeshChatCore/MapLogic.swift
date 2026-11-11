import Foundation
import MeshCoreKit

/// A message's route as stops on the map: where it started, each repeater on the way, and where it
/// ended. Only nodes with a known position can be drawn; `hidden` counts the ones that can't.
public struct MapRoute: Hashable, Sendable {
    public struct Stop: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let kind: MapContent.Point.Kind
        public let position: Position

        public init(id: String, name: String, kind: MapContent.Point.Kind, position: Position) {
            self.id = id; self.name = name; self.kind = kind; self.position = position
        }
    }

    public let title: String
    /// in the order the message travelled
    public let stops: [Stop]
    /// repeaters on the route whose position isn't known (or whose ID several share and none is near)
    public let hidden: Int
    public let hops: Int

    public init(title: String, stops: [Stop], hidden: Int, hops: Int) {
        self.title = title; self.stops = stops; self.hidden = hidden; self.hops = hops
    }

    /// Incoming: the sender (when their position is known), then each repeater, then you at home.
    /// Outgoing (a channel message's echo): you at home, then the repeaters that passed it on.
    public static func of(_ m: Message, directory: NodeDirectory, sender: Contact?) -> MapRoute {
        let ids = NodeDirectory.split(m.path, hashSize: m.hashSize)
        let incoming = m.direction == .incoming
        let hops = incoming ? directory.resolve(incoming: ids) : directory.resolve(outgoing: ids)
        var stops: [Stop] = hops.compactMap { h in
            guard let n = h.node, let p = n.position else { return nil }
            return Stop(id: n.key, name: n.name, kind: n.type == .room ? .room : .repeater, position: p)
        }
        let home = directory.home.map { Stop(id: "home", name: String(localized: "You", comment: "Your place on a message's route on the map"), kind: .home, position: $0) }
        if incoming {
            if let s = sender, let p = s.position {
                stops.insert(Stop(id: s.key.hex, name: s.name, kind: s.type == .room ? .room : .person, position: p), at: 0)
            }
            if let home { stops.append(home) }
        } else if let home {
            stops.insert(home, at: 0)
        }
        let title = incoming ? m.sender.map { String(localized: "\($0) → you") } ?? String(localized: "Message → you") : String(localized: "Your message")
        return MapRoute(title: title, stops: stops, hidden: hops.filter { $0.node?.position == nil }.count, hops: ids.count)
    }

    /// Something worth drawing: at least two places to join.
    public var isDrawable: Bool { stops.count >= 2 }

    /// The line, in order.
    public var positions: [Position] { stops.map(\.position) }

    /// The stops as map markers, each once (a path can pass the same repeater twice).
    public var points: [MapContent.Point] {
        var seen = Set<String>()
        return stops.filter { seen.insert($0.id).inserted }.map {
            MapContent.Point(id: $0.id, name: $0.name, kind: $0.kind, position: $0.position, isContact: true, lastHeard: nil)
        }
    }

    /// "Ala → SP9-Rep → You"
    public var summary: String { stops.map(\.name).joined(separator: " → ") }
}

/// What the map draws at a zoom level: single nodes, or clusters of the ones too close to tell apart.
public enum MapMark: Hashable, Sendable, Identifiable {
    case point(MapContent.Point)
    case cluster(MapCluster)

    public var id: String {
        switch self {
        case .point(let p): p.id
        case .cluster(let c): c.id
        }
    }

    public var position: Position {
        switch self {
        case .point(let p): p.position
        case .cluster(let c): c.position
        }
    }
}

public struct MapCluster: Hashable, Sendable, Identifiable {
    public let id: String
    /// the middle of its nodes
    public let position: Position
    public let count: Int
    public let south: Double, west: Double, north: Double, east: Double
    /// the most common kind among its nodes (for its colour)
    public let kind: MapContent.Point.Kind
}

public enum MapClustering {
    /// Grid clustering in screen space: nodes within the same cell of `cell` points at this zoom become
    /// one cluster. From zoom 14 nothing clusters, and `apart` (home, the selected node) never does.
    public static func marks(_ points: [MapContent.Point], zoom: Int, cell: Double = 56, apart: Set<String> = []) -> [MapMark] {
        guard zoom < 14 else { return points.map { .point($0) } }
        let scale = 256 * pow(2, Double(zoom))
        var cells: [String: [MapContent.Point]] = [:]
        var out: [MapMark] = []
        for p in points {
            if p.kind == .home || apart.contains(p.id) { out.append(.point(p)); continue }
            let (x, y) = project(p.position, scale: scale)
            cells["\(Int(floor(x / cell))):\(Int(floor(y / cell)))", default: []].append(p)
        }
        for (key, group) in cells.sorted(by: { $0.key < $1.key }) {
            if group.count == 1 { out.append(.point(group[0])); continue }
            let lats = group.map(\.position.latitude), lons = group.map(\.position.longitude)
            let kinds = Dictionary(grouping: group, by: \.kind).max { a, b in (a.value.count, b.key.rawValue) < (b.value.count, a.key.rawValue) }?.key ?? .repeater
            out.append(.cluster(MapCluster(
                id: "cluster-\(zoom)-\(key)",
                position: Position(latitude: lats.reduce(0, +) / Double(group.count), longitude: lons.reduce(0, +) / Double(group.count)),
                count: group.count, south: lats.min()!, west: lons.min()!, north: lats.max()!, east: lons.max()!, kind: kinds)))
        }
        return out
    }

    /// Web Mercator, in points at this scale (256 × 2^zoom across the world).
    static func project(_ p: Position, scale: Double) -> (Double, Double) {
        let lat = max(-85.05, min(85.05, p.latitude)) * .pi / 180
        let x = (p.longitude + 180) / 360 * scale
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * scale
        return (x, y)
    }
}
