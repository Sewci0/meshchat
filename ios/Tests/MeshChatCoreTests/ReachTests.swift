import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// The reach check: who answered and how well, who stayed quiet, what to tell the user; and the badge.

private let now = Date(timeIntervalSince1970: 1_794_000_000)

@Suite("Reach")
struct ReachTests {
    let olsztyn = "3900aabbccddeeff00112233445566778899aabbccddeeff0011223344556677"
    let mimas = "83d7aabbccddeeff00112233445566778899aabbccddeeff0011223344556677"
    let oberon = "5017aabbccddeeff00112233445566778899aabbccddeeff0011223344556677"

    func answer(_ key: String, up: Double, down: Double) -> DiscoveryAnswer {
        DiscoveryAnswer(nodeType: .repeater, keyPrefix: Data(hex: String(key.prefix(16)))!, snrThere: up, snrHere: down, rssi: -100)
    }

    @Test func answersAreNamedAndJudgedByTheWeakerWay() {
        let check = ReachCheck(answers: [answer(mimas, up: -1, down: 9), answer(olsztyn, up: 8, down: 6)],
                               candidates: [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 120),
                                            .init(key: olsztyn, name: "Olsztyn Jura RPT", lastDirect: now - 60)],
                               nodes: [olsztyn: "Olsztyn Jura RPT", mimas: "SLU-MIMAS"], lastHeard: now - 30, spreadingFactor: 6, now: now)
        #expect(check.rows.map(\.name) == ["Olsztyn Jura RPT", "SLU-MIMAS", "SLU-OBERON"])   // best first, then the quiet one
        #expect(check.rows[0].verdict == .good)        // weaker way +6: 11 dB over SF6's −5
        #expect(check.rows[1].verdict == .weak)        // −1 up, though 9 down
        #expect(!check.rows[2].answered && check.rows[2].lastDirect == now - 120)
        #expect(check.diagnosis == .reachable(count: 2, best: "Olsztyn Jura RPT"))
    }

    @Test func silenceIsDiagnosed() {
        let hearOnly = ReachCheck(answers: [], candidates: [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 90 * 60)],
                                  nodes: [:], lastHeard: now - 60, spreadingFactor: 6, now: now)
        #expect(hearOnly.diagnosis == .hearOnly)
        #expect(hearOnly.rows.isEmpty)   // heard 90 minutes ago: not expected to answer
        let deaf = ReachCheck(answers: [], candidates: [], nodes: [:], lastHeard: now - 3600, spreadingFactor: 6, now: now)
        #expect(deaf.diagnosis == .deaf)
        // an answer from a repeater nobody knows yet: named by its key
        let unknown = ReachCheck(answers: [answer("abcdef0123456789", up: 3, down: 3)], candidates: [], nodes: [:], lastHeard: nil,
                                 spreadingFactor: 8, now: now)
        #expect(unknown.rows.first?.name == "abcdef01" && unknown.rows.first?.key == nil)
    }

    @Test func aNewRepeaterThatAnswered() {
        // the case in the screenshot: right after a switch, one answer from a repeater not heard yet
        let fresh = "d3ab6eff01234567"
        let check = ReachCheck(answers: [answer(fresh, up: 5.2, down: 2.5)], candidates: [], nodes: [:], lastHeard: now - 30,
                               spreadingFactor: 8, now: now)
        let row = try! #require(check.rows.first)
        #expect(row.isNew && row.id == fresh && row.name == "d3ab6eff")
        #expect(check.summary.title == "A new repeater (d3ab6eff) hears you: good")
        // answering a zero-hop check is being heard directly: 1, not 0
        #expect(check.heardDirectly(recent: []) == 1)
        // counted once when it's also heard directly (matched by the start of its key), and added to others
        let full = fresh + String(repeating: "ab", count: 24)
        #expect(check.heardDirectly(recent: [full]) == 1)
        #expect(check.heardDirectly(recent: [olsztyn, oberon]) == 3)
        // once its advert is heard: named, linked by its key
        let known = row.known(as: full, name: "SLU-NEW")
        #expect(!known.isNew && known.key == full && known.id == full && known.verdict == row.verdict && known.up == 5.2)
    }

    @Test func silentRepeatersArePinged() {
        let candidates: [ReachCheck.Candidate] = [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 120),
                                                  .init(key: olsztyn, name: "Olsztyn Jura RPT", lastDirect: now - 60),
                                                  .init(key: mimas, name: "SLU-MIMAS", lastDirect: now - 3600)]
        // nobody answered the broadcast (older repeater firmware doesn't): ping the ones heard lately
        let targets = ReachCheck.pingTargets(answers: [], candidates: candidates, now: now)
        #expect(targets.map(\.name) == ["Olsztyn Jura RPT", "SLU-OBERON"])   // SLU-MIMAS: an hour ago
        #expect(ReachCheck.pingTargets(answers: [answer(olsztyn, up: 5, down: 5)], candidates: candidates, now: now).map(\.name) == ["SLU-OBERON"])

        let check = ReachCheck(answers: [], candidates: candidates, nodes: [:], lastHeard: now - 30, spreadingFactor: 6,
                               pings: [olsztyn: (up: 6, down: 4), oberon: nil], now: now)
        #expect(check.diagnosis == .reachable(count: 1, best: "Olsztyn Jura RPT"))
        #expect(check.rows.first?.byPing == true && check.rows.first?.verdict == .marginal)   // weaker way +4: 9 dB over the floor
        #expect(check.rows.last?.name == "SLU-OBERON" && check.rows.last?.answered == false && check.rows.last?.byPing == true)
        #expect(check.broadcastAnswers == 0 && check.pinged == 2 && check.pingAnswers == 1)
    }

    @Test func oneMarginalAnswerIsSaidSo() {
        // the case in the screenshot: one answer, +2.8 up / +3.8 down at SF6 (7.8 dB over the floor)
        let check = ReachCheck(answers: [answer(olsztyn, up: 2.8, down: 3.8)],
                               candidates: [.init(key: olsztyn, name: "Olsztyn Jura RPT", lastDirect: now - 60)],
                               nodes: [olsztyn: "Olsztyn Jura RPT"], lastHeard: now - 30, spreadingFactor: 6, now: now)
        #expect(check.level == .marginal)   // never shown as good (green) with a marginal best
        #expect(check.summary == ReachCheck.Summary(level: .marginal, title: "Olsztyn Jura RPT hears you: marginal", detail: nil))
        #expect(check.best?.name == "Olsztyn Jura RPT")
    }

    @Test func severalAnswersNameTheBestOnlyWhenItsGood() {
        let good = ReachCheck(answers: [answer(olsztyn, up: 8, down: 9), answer(mimas, up: 1, down: 2)], candidates: [],
                              nodes: [olsztyn: "Olsztyn Jura RPT", mimas: "SLU-MIMAS"], lastHeard: now, spreadingFactor: 6, now: now)
        #expect(good.summary == ReachCheck.Summary(level: .good, title: "2 repeaters hear you", detail: "best: Olsztyn Jura RPT"))
        let weak = ReachCheck(answers: [answer(olsztyn, up: -2, down: 9), answer(mimas, up: -3, down: 2)], candidates: [],
                              nodes: [olsztyn: "Olsztyn Jura RPT", mimas: "SLU-MIMAS"], lastHeard: now, spreadingFactor: 6, now: now)
        #expect(weak.summary == ReachCheck.Summary(level: .weak, title: "2 repeaters hear you: best is weak", detail: nil))
        #expect(ReachCheck.Verdict.weak < .marginal && ReachCheck.Verdict.marginal < .good)
    }

    @Test func noAnswersSayWhy() {
        let hearOnly = ReachCheck(answers: [], candidates: [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 120)],
                                  nodes: [:], lastHeard: now - 60, spreadingFactor: 6, now: now)
        #expect(hearOnly.level == .hearOnly)
        #expect(hearOnly.summary.title == "No repeater heard you" && hearOnly.summary.detail == "Check antenna and power, or move higher.")
        let deaf = ReachCheck(answers: [], candidates: [], nodes: [:], lastHeard: now - 3600, spreadingFactor: 6, now: now)
        #expect(deaf.level == .deaf && deaf.summary.title == "Radio hears nothing")
    }

    @Test func aFailedPingStillCounts() {
        let check = ReachCheck(answers: [], candidates: [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 120)],
                               nodes: [:], lastHeard: now - 30, spreadingFactor: 6, pings: [oberon: nil], now: now)
        #expect(check.pinged == 1 && check.pingAnswers == 0)
        #expect(check.rows.first?.byPing == true && check.rows.first?.answered == false)
    }

    @Test func aManualPingMovesTheRowUp() {
        let candidates: [ReachCheck.Candidate] = [.init(key: oberon, name: "SLU-OBERON", lastDirect: now - 120),
                                                  .init(key: olsztyn, name: "Olsztyn Jura RPT", lastDirect: now - 60)]
        let check = ReachCheck(answers: [answer(olsztyn, up: 2, down: 3)], candidates: candidates,
                               nodes: [olsztyn: "Olsztyn Jura RPT"], lastHeard: now - 30, spreadingFactor: 6, now: now)
        #expect(check.rows.map(\.name) == ["Olsztyn Jura RPT", "SLU-OBERON"] && !check.rows[1].answered)
        // pinged by hand later: it answered better than the broadcast's best, so it leads now
        let after = check.adding(ping: (up: 9, down: 8), for: oberon)
        #expect(after.rows.map(\.name) == ["SLU-OBERON", "Olsztyn Jura RPT"])
        #expect(after.rows[0].byPing && after.rows[0].verdict == .good)
        #expect(after.at == check.at && after.pinged == 1 && after.pingAnswers == 1)
        #expect(after.summary.title == "2 repeaters hear you" && after.summary.detail == "best: SLU-OBERON")
        // and a ping that got nothing back marks it as tried
        let failed = check.adding(ping: nil, for: oberon)
        #expect(failed.rows[1].byPing && !failed.rows[1].answered && failed.pinged == 1)
    }

    @Test func unknownAnswerersDontShareAnID() {
        let check = ReachCheck(answers: [answer("abcdef0123456789", up: 3, down: 3), answer("abcdef01ffffffff", up: 2, down: 2)],
                               candidates: [], nodes: [:], lastHeard: nil, spreadingFactor: 6, now: now)
        #expect(Set(check.rows.map(\.id)).count == 2)   // both named "abcdef01"
    }

    @Test func floorsAndWaits() {
        #expect(ReachCheck.floor(spreadingFactor: 6) == -5 && ReachCheck.floor(spreadingFactor: 12) == -20)
        #expect(ReachCheck.verdict(up: 2, down: 4, spreadingFactor: 6) == .marginal)
        #expect(ReachCheck.wait(after: nil, now: now) == 0)
        #expect(ReachCheck.wait(after: now - 45, now: now) == 15)
        #expect(ReachCheck.wait(after: now - 120, now: now) == 0)
    }

    @Test func theBadge() {
        #expect(Freshness(lastDirect: now - 60, now: now) == .live)
        #expect(Freshness(lastDirect: now - 20 * 60, now: now) == .recent)
        #expect(Freshness(lastDirect: now - 3 * 3600, now: now) == .stale)
        #expect(Freshness(lastDirect: nil, now: now) == .never)
    }
}

@Suite("Mesh pulse")
struct MeshPulseTests {
    @Test func bucketsAndSignal() {
        let now = Date(timeIntervalSince1970: 1_794_000_000 + 120)   // 2 minutes into a 5-minute bucket
        let packets: [(date: Date, hops: Int, path: String, hashSize: Int, snr: Double)] = [
            (now - 30, 2, "39003702", 2, 6.4),        // last hop 3702
            (now - 200, 1, "83d7", 2, -1.0),          // last hop 83d7
            (now - 400, 3, "aabb3702ccdd", 2, 2.0),   // last hop ccdd
            (now - 1200, 0, "", 2, 9.0),              // direct, no repeater
            (now - 2400, 1, "5017", 2, 4.0),          // 40 minutes ago: not "lately"
            (now - 4000, 1, "9797", 2, 4.0),          // over an hour: no bucket
        ]
        let p = MeshPulse(packets: packets, now: now)
        #expect(p.rate.count == 12)
        #expect(p.rateEnd.timeIntervalSince1970 == 1_794_000_000 + 300)
        #expect(p.rate[11] == 1 && p.rate[10] == 2 && p.rate.reduce(0) { $0 + Int($1) } == 5)   // this bucket, the one before
        #expect(p.perHour == 5)
        #expect(p.heardAt == now - 30)
        #expect(p.snr == 2)                           // median of 6.4, −1, 2 (the last 15 minutes)
        #expect(MeshPulse(packets: [], now: now).snr == nil)
    }

    @Test func levels() {
        #expect(MeshPulse.level(snr: 7, spreadingFactor: 6) == 3)
        #expect(MeshPulse.level(snr: 1, spreadingFactor: 6) == 2)
        #expect(MeshPulse.level(snr: -3, spreadingFactor: 6) == 1)
        #expect(MeshPulse.level(snr: -6, spreadingFactor: 6) == 0)
    }
}
