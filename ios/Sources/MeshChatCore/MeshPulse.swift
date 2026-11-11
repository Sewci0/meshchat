import Foundation

/// The mesh at a glance, for the lock screen: packets per 5 minutes over the last hour, and the signal of
/// what arrives lately. (Repeaters heard directly come from `RepeaterAnalysis`, which resolves their IDs.)
public struct MeshPulse: Sendable, Equatable {
    /// 12 five-minute buckets, aligned to the clock, oldest first (clamped to 255)
    public let rate: [UInt8]
    /// the end of the newest bucket
    public let rateEnd: Date
    /// packets in the last hour
    public let perHour: Int
    /// the newest packet
    public let heardAt: Date?
    /// median SNR of the last 15 minutes, in whole dB
    public let snr: Int?

    public static let buckets = 12, bucket: TimeInterval = 300

    /// - packets: date, hop count, path (hex) and ID size of each packet heard, any order
    public init(packets: [(date: Date, hops: Int, path: String, hashSize: Int, snr: Double)], now: Date = .now) {
        let end = (now.timeIntervalSince1970 / Self.bucket).rounded(.up) * Self.bucket
        let start = end - Self.bucket * Double(Self.buckets)
        var counts = [Int](repeating: 0, count: Self.buckets)
        var recent: [Double] = []
        var newest: Date?
        for p in packets {
            let t = p.date.timeIntervalSince1970
            if t >= start, t < end { counts[min(Self.buckets - 1, Int((t - start) / Self.bucket))] += 1 }
            if now.timeIntervalSince(p.date) <= 15 * 60 { recent.append(p.snr) }
            if newest.map({ p.date > $0 }) ?? true { newest = p.date }
        }
        rate = counts.map { UInt8(min($0, 255)) }
        rateEnd = Date(timeIntervalSince1970: end)
        perHour = packets.filter { now.timeIntervalSince($0.date) <= 3600 }.count
        heardAt = newest
        snr = recent.isEmpty ? nil : Int(recent.sorted()[recent.count / 2].rounded())
    }

    /// 3 good, 2 marginal, 1 weak, 0 below what still decodes, by how far the signal is above the floor
    /// at this spreading factor.
    public static func level(snr: Int, spreadingFactor sf: Int) -> Int {
        let margin = Double(snr) - ReachCheck.floor(spreadingFactor: sf)
        return margin >= 10 ? 3 : margin >= 5 ? 2 : margin > 0 ? 1 : 0
    }
}
