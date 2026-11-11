import Foundation
import MeshCoreKit

/// An area of map to keep on the device: a box and the zoom levels. Web-Mercator tile maths, to show how
/// big a download is before it starts.
public struct OfflineRegion: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var south: Double, west: Double, north: Double, east: Double
    public var minZoom: Int, maxZoom: Int
    public var id: String { name }

    public init(name: String, south: Double, west: Double, north: Double, east: Double, minZoom: Int = 0, maxZoom: Int = 14) {
        self.name = name; self.south = south; self.west = west; self.north = north; self.east = east
        self.minZoom = minZoom; self.maxZoom = maxZoom
    }

    /// A square around a point, `radiusKm` each way.
    public static func around(_ p: Position, radiusKm: Double, name: String, maxZoom: Int = 14) -> OfflineRegion {
        let dLat = radiusKm / 111.32
        let dLon = radiusKm / (111.32 * max(0.01, cos(p.latitude * .pi / 180)))
        return OfflineRegion(name: name, south: max(-85, p.latitude - dLat), west: max(-180, p.longitude - dLon),
                             north: min(85, p.latitude + dLat), east: min(180, p.longitude + dLon), maxZoom: maxZoom)
    }

    static func tile(_ lat: Double, _ lon: Double, _ z: Int) -> (x: Int, y: Int) {
        let n = pow(2, Double(z))
        let x = Int(((lon + 180) / 360 * n).rounded(.down))
        let r = lat * .pi / 180
        let y = Int(((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n).rounded(.down))
        let maxIndex = Int(n) - 1
        return (min(max(0, x), maxIndex), min(max(0, y), maxIndex))
    }

    /// Tiles the region covers at each zoom, summed.
    public var tileCount: Int {
        (minZoom...maxZoom).reduce(0) { sum, z in
            let a = Self.tile(north, west, z), b = Self.tile(south, east, z)
            return sum + (b.x - a.x + 1) * (b.y - a.y + 1)
        }
    }

    /// The most tiles one download may have (about 150 km around a point at street level), to be fair to
    /// the free tile service.
    public static let maxTiles = 100_000

    /// A rough download size: vector tiles average around 25 KB in towns, much less over fields.
    public var estimatedBytes: Int { tileCount * 25_000 }

    public func contains(_ p: Position) -> Bool {
        (south...north).contains(p.latitude) && (west...east).contains(p.longitude)
    }
}
