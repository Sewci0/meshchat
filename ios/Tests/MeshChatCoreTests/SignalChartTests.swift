import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// The repeater page's charts: signal levels and bands that follow the spreading factor, the y range
// and words as the web app has them, and the 3-hour activity in 10-minute steps.

private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

private func points(_ snrs: [Double], every s: TimeInterval = 60) -> [RepeaterAnalysis.SignalPoint] {
    snrs.enumerated().map { i, v in RepeaterAnalysis.SignalPoint(date: t0 + Double(i) * s, snr: v, rssi: -100, type: "ADVERT") }
}

@Suite("Signal chart")
struct SignalChartTests {
    @Test func levelsFollowTheSpreadingFactor() {
        // SF6 decodes down to −5 dB: at the limit is marginal, 5 above fair, 10 above good
        #expect(SignalLevel(snr: -5.1, spreadingFactor: 6) == .below)
        #expect(SignalLevel(snr: -5, spreadingFactor: 6) == .marginal)
        #expect(SignalLevel(snr: 4.9, spreadingFactor: 6) == .fair)
        #expect(SignalLevel(snr: 5, spreadingFactor: 6) == .good)
        // SF8 decodes down to −10 dB, so the same −6 dB is marginal there
        #expect(SignalLevel(snr: -6, spreadingFactor: 6) == .below)
        #expect(SignalLevel(snr: -6, spreadingFactor: 8) == .marginal)
    }

    @Test func rangeTicksAndBandsAtSF6() {
        let c = SignalChartModel(points: points([2, 4]), spreadingFactor: 6)
        #expect(c.floor == -5)
        #expect(c.step == 5)
        #expect(c.lo == -10 && c.hi == 10)
        #expect(c.ticks == [-10, -5, 0, 5, 10])
        #expect(c.bands.map(\.level) == [.below, .marginal, .fair, .good])
        #expect(c.bands.map(\.from) == [-10, -5, 0, 5])
        #expect(c.bands.map(\.to) == [-5, 0, 5, 10])
    }

    @Test func bandsMoveWithTheNetwork() {
        let c = SignalChartModel(points: points([2, 4]), spreadingFactor: 8)
        #expect(c.floor == -10)
        #expect(c.bands.first { $0.level == .marginal }?.from == -10)
        #expect(c.bands.first { $0.level == .good }?.from == 0)
        #expect(c.lo == -15)
    }

    @Test func wideSpreadsUseTenDecibelSteps() {
        let c = SignalChartModel(points: points([-12, 25]), spreadingFactor: 6)
        #expect(c.step == 10)
        #expect(c.lo == -20 && c.hi == 30)
        // bands stay inside the range
        #expect(c.bands.allSatisfy { $0.from >= c.lo && $0.to <= c.hi && $0.to > $0.from })
    }

    @Test func noSpreadingFactorMeansNoLevels() {
        let c = SignalChartModel(points: points([2, 4]), spreadingFactor: nil)
        #expect(c.floor == nil)
        #expect(c.bands.isEmpty)
        #expect(c.level(3) == nil)
        #expect(c.reading == "Latest +4 dB, median +4 dB, weakest +2 dB.")
        #expect(!c.accessibilitySummary.contains("Decoding stops"))
    }

    @Test func runningMedianIsCentred() {
        #expect(SignalChartModel.runningMedian([5, 1, 3], window: 3) == [5, 3, 3])
        #expect(SignalChartModel.runningMedian([], window: 15).isEmpty)
        #expect(SignalChartModel.runningMedian([1, 9, 2, 8, 3], window: 15) == [3, 3, 3, 3, 3])
    }

    @Test func nearestPacketAndDomain() {
        let c = SignalChartModel(points: points([1, 2, 3], every: 10), spreadingFactor: 6)
        #expect(c.nearest(to: t0 + 5) == 0)    // a tie goes to the earlier one
        #expect(c.nearest(to: t0 + 16) == 2)
        #expect(c.nearest(to: t0 - 100) == 0)
        #expect(c.nearest(to: t0 + 999) == 2)
        // a burst gets the 10 minutes before it; the axis ends at the newest packet
        #expect(c.domain == (t0 + 20 - 600)...(t0 + 20))
        let one = SignalChartModel(points: points([1]), spreadingFactor: 6)
        #expect(one.domain.upperBound.timeIntervalSince(one.domain.lowerBound) == 600)
    }

    @Test func keepsTheNewestInOrder() {
        let shuffled = points([1, 2, 3, 4]).reversed()
        let c = SignalChartModel(points: Array(shuffled), spreadingFactor: 6, limit: 2)
        #expect(c.points.map(\.snr) == [3, 4])
    }

    @Test func wordsAsTheWebAppWritesThem() {
        #expect(SignalChartModel.db(3.5) == "+3.5")
        #expect(SignalChartModel.db(-5) == "−5")
        #expect(SignalChartModel.db(0.04) == "0")
        #expect(SignalChartModel.db(2.0) == "+2")
        let c = SignalChartModel(points: points([-6.5, 2, 3.5]), spreadingFactor: 6)
        #expect(c.reading == "Latest +3.5 dB (8.5 dB above the decode limit: fair), median +2 dB, weakest −6.5 dB.")
        let weak = SignalChartModel(points: points([-6.5]), spreadingFactor: 6)
        #expect(weak.reading == "Latest −6.5 dB (1.5 dB below the decode limit: below the limit), median −6.5 dB, weakest −6.5 dB.")
        #expect(c.accessibilitySummary.hasSuffix("Decoding stops below −5 dB at SF6; marginal up to 5 dB above that, fair up to 10, good beyond."))
    }

    @Test func whetherItHearsYou() {
        #expect(SignalChartModel.hearsYou(count: 1, last: t0 - 7200, direct: true, now: t0)
                == "It hears you: it was the first repeater to pass on one of your messages, last 2 h ago.")
        #expect(SignalChartModel.hearsYou(count: 3, last: t0 - 10, direct: true, now: t0)?.contains("3 of your messages, just now") == true)
        #expect(SignalChartModel.hearsYou(count: 0, last: nil, direct: true)?.hasPrefix("No sign yet") == true)
        #expect(SignalChartModel.hearsYou(count: 0, last: nil, direct: false) == nil)
    }

    @Test func activityIsTenMinuteStepsOverThreeHours() {
        let now = t0
        let rpt = Contact(key: PublicKey(hex: "39" + String(repeating: "aa", count: 31))!, type: .repeater, name: "A",
                          position: Position(latitude: 50.81, longitude: 19.11))
        let dir = NodeDirectory(contacts: [rpt], heard: [], home: nil)
        let ages: [Int] = [0, 599, 600, 3 * 3600 - 1, 3 * 3600]
        let packets = ages.map { (age: Int) -> PacketRecord in
            let fp = Int64(age + 1)   // each its own packet
            return PacketRecord(date: now - Double(age), route: "flood", type: "GRP_TXT", hops: 1, path: "39", hashSize: 1, snr: 5,
                                rssi: -100, fingerprint: fp, raw: Data([0x15, 0]))
        }
        let a = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, days: 1, now: now)
        let act = a.summary(rpt.key.hex).activity
        #expect(act.count == 18)
        #expect(act[17] == 2)   // now and 9 min 59 s ago
        #expect(act[16] == 1)   // 10 minutes ago
        #expect(act[0] == 1)    // just under 3 hours ago
        #expect(act.reduce(0, +) == 4)   // 3 hours ago is out
        #expect(a.days == 1)
    }
}
