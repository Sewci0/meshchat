import Foundation

/// How much headroom a signal has above the weakest one LoRa still decodes at the radio's spreading
/// factor, graded as the web app grades it. You only ever see the packets that made it, so a signal
/// just above the limit looks better than the link is: below the limit (it got through by luck),
/// marginal (0–5 dB: fading and collisions lose many packets), fair (5–10 dB), good (10 dB and more,
/// the fade margin a link wants).
public enum SignalLevel: Int, Sendable, CaseIterable {
    case below = 1, marginal, fair, good

    public var name: String {
        switch self {
        case .below: String(localized: "below the limit", comment: "Signal level: below the weakest signal LoRa decodes")
        case .marginal: String(localized: "marginal", comment: "Signal level")
        case .fair: String(localized: "fair", comment: "Signal level")
        case .good: String(localized: "good", comment: "Signal level")
        }
    }

    /// headroom (dB above the decode limit) where marginal, fair and good begin
    public static let steps: [Double] = [0, 5, 10]

    public init(snr: Double, spreadingFactor sf: Int) {
        let margin = snr - ReachCheck.floor(spreadingFactor: sf)
        self = margin < Self.steps[0] ? .below : margin < Self.steps[1] ? .marginal : margin < Self.steps[2] ? .fair : .good
    }
}

/// "Signal at your radio", worked out for drawing: the packets heard straight from a repeater, a
/// running median through them, the y range and ticks the web chart uses, and the signal levels as
/// bands for the radio's spreading factor (none when it isn't known), plus the words under it.
public struct SignalChartModel: Sendable, Equatable {
    public struct Band: Sendable, Equatable {
        public let level: SignalLevel
        public let from: Double
        public let to: Double
    }

    /// oldest first, at most `limit`
    public let points: [RepeaterAnalysis.SignalPoint]
    public let spreadingFactor: Int?
    /// where decoding stops at that spreading factor
    public let floor: Double?
    public let lo: Double, hi: Double, step: Double
    public let ticks: [Double]
    public let bands: [Band]
    /// the running median at each point
    public let trend: [Double]
    /// ends at the newest packet (never in time still to come); a burst gets 10 minutes before it
    public let domain: ClosedRange<Date>
    public let latest: Double?, median: Double?, weakest: Double?

    public init(points: [RepeaterAnalysis.SignalPoint], spreadingFactor sf: Int?, limit: Int = 500, now: Date = .now) {
        let pts = Array(points.sorted { $0.date < $1.date }.suffix(limit))
        self.points = pts
        spreadingFactor = sf
        let floor = sf.map { ReachCheck.floor(spreadingFactor: $0) }
        self.floor = floor

        let snrs = pts.map(\.snr)
        let sorted = snrs.sorted()
        latest = snrs.last
        median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        weakest = sorted.first

        // as the web chart: 10 dB steps for a wide spread, room below the limit and above good
        let floors = floor.map { [$0] } ?? []
        let spread = (snrs.max() ?? floor ?? 0) - ((snrs + floors).min() ?? 0)
        let step: Double = spread > 30 ? 10 : 5
        self.step = step
        let low = (snrs + (floor.map { [$0 - 2.5] } ?? [])).min() ?? -10
        let high = (snrs + (floor.map { [$0 + 10] } ?? [])).max() ?? 10
        let lo = ((low - 1) / step).rounded(.down) * step
        let hi = max(((high + 1) / step).rounded(.up) * step, lo + step)
        self.lo = lo
        self.hi = hi
        ticks = Array(stride(from: lo, through: hi, by: step))

        if let floor {
            let edges = [lo] + SignalLevel.steps.map { floor + $0 } + [hi]
            bands = SignalLevel.allCases.enumerated().compactMap { i, level in
                let from = max(lo, edges[i]), to = min(hi, edges[i + 1])
                return to > from ? Band(level: level, from: from, to: to) : nil
            }
        } else {
            bands = []
        }

        trend = Self.runningMedian(snrs)
        let last = pts.last?.date ?? now
        domain = min(pts.first?.date ?? last, last.addingTimeInterval(-600))...last
    }

    /// A centred running median over `window` values (fewer at the ends).
    public static func runningMedian(_ v: [Double], window: Int = 15) -> [Double] {
        let half = window / 2
        return v.indices.map { i in
            let s = v[max(0, i - half)..<min(v.count, i + half + 1)].sorted()
            return s[s.count / 2]
        }
    }

    /// The packet nearest in time (the earlier one on a tie).
    public func nearest(to date: Date) -> Int? {
        guard !points.isEmpty else { return nil }
        var a = 0, b = points.count - 1
        while b - a > 1 {
            let m = (a + b) / 2
            if points[m].date < date { a = m } else { b = m }
        }
        return abs(points[a].date.timeIntervalSince(date)) <= abs(points[b].date.timeIntervalSince(date)) ? a : b
    }

    public func level(_ snr: Double) -> SignalLevel? { spreadingFactor.map { SignalLevel(snr: snr, spreadingFactor: $0) } }

    /// "+3.5", "−5", "0": dB as the web app writes them, to a tenth
    public static func db(_ v: Double) -> String {
        let r = (abs(v) * 10).rounded() / 10
        let n = r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        return r == 0 ? "0" : (v > 0 ? "+" : "−") + n
    }

    /// The line under the chart: the latest packet against the limit, the median and the weakest.
    public var reading: String? {
        guard let latest, let median, let weakest else { return nil }
        let l = Self.db(latest), m = Self.db(median), w = Self.db(weakest)
        // the whole line as one sentence, above or below the limit, for translation
        if let floor, let level = level(latest) {
            let margin = ((latest - floor) * 10).rounded() / 10
            let by = Self.db(abs(margin)).replacingOccurrences(of: "+", with: "")
            return margin >= 0
                ? String(localized: "Latest \(l) dB (\(by) dB above the decode limit: \(level.name)), median \(m) dB, weakest \(w) dB.")
                : String(localized: "Latest \(l) dB (\(by) dB below the decode limit: \(level.name)), median \(m) dB, weakest \(w) dB.")
        }
        return String(localized: "Latest \(l) dB, median \(m) dB, weakest \(w) dB.")
    }

    /// Whether it hears you: it was the first repeater to pass on one of your messages.
    public static func hearsYou(count: Int, last: Date?, direct: Bool, now: Date = .now) -> String? {
        if count > 0 {
            // whole sentences: one message or several, and when the last was (if known)
            guard let d = last else {
                return count == 1 ? String(localized: "It hears you: it was the first repeater to pass on one of your messages.")
                    : String(localized: "It hears you: it was the first repeater to pass on \(count) of your messages.")
            }
            let a = NodeCard.ago(d, now: now)
            if a == String(localized: "now") {
                return count == 1 ? String(localized: "It hears you: it was the first repeater to pass on one of your messages, just now.")
                    : String(localized: "It hears you: it was the first repeater to pass on \(count) of your messages, just now.")
            }
            return count == 1 ? String(localized: "It hears you: it was the first repeater to pass on one of your messages, last \(a) ago.")
                : String(localized: "It hears you: it was the first repeater to pass on \(count) of your messages, last \(a) ago.")
        }
        return direct ? String(localized: "No sign yet that it hears you: none of your channel messages came back through it first.") : nil
    }

    /// What VoiceOver reads for the whole chart.
    public var accessibilitySummary: String {
        guard let latest, let median else { return String(localized: "Signal at your radio: no packets heard straight from it yet.") }
        let n = points.count, m = Self.db(median), l = Self.db(latest)
        // the first sentence whole: one packet or several, with the median's level if known
        var s: String
        if let level = level(median) {
            s = n == 1 ? String(localized: "Signal at your radio: 1 packet, median \(m) dB (\(level.name)), latest \(l) dB.")
                : String(localized: "Signal at your radio: \(n) packets, median \(m) dB (\(level.name)), latest \(l) dB.")
        } else {
            s = n == 1 ? String(localized: "Signal at your radio: 1 packet, median \(m) dB, latest \(l) dB.")
                : String(localized: "Signal at your radio: \(n) packets, median \(m) dB, latest \(l) dB.")
        }
        if let floor, let sf = spreadingFactor {
            s += " " + String(localized: "Decoding stops below \(Self.db(floor)) dB at SF\(sf); marginal up to 5 dB above that, fair up to 10, good beyond.")
        }
        return s
    }
}
