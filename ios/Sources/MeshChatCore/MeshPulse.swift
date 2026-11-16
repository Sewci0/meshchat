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

/// People heard lately, for the lock screen: whether the mesh is alive right now. Those who wrote (in a
/// channel, a room or a direct message) and those whose advert arrived, each counted once however their
/// name is spelt (channel messages carry only a name, adverts a key too), and never you.
public enum PeopleHeard {
    public static let window: TimeInterval = 3600

    /// Whether a message that arrived in the window was also written in it. Messages the radio kept while
    /// the phone was away, and a room's older posts, arrive late: the sender's clock says when they were
    /// written, if it's plausibly right (within a day of ours; a clock never set doesn't decide).
    public static func writtenLately(senderTimestamp: UInt32?, now: Date = .now) -> Bool {
        guard let ts = senderTimestamp else { return true }
        let age = now.timeIntervalSince1970 - Double(ts)
        return abs(age) > 86400 || age <= window + 600
    }

    /// - writers: the senders of messages that arrived in the window
    /// - advertisers: the names of people (not repeaters, rooms or sensors) whose advert arrived in it
    public static func count(writers: [String], advertisers: [String], me: String?) -> Int {
        let mine = me.map(Mentions.normalized)
        return Set((writers + advertisers).map(Mentions.normalized).filter { !$0.isEmpty && $0 != mine }).count
    }
}
