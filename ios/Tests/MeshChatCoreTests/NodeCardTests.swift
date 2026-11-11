import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// The map's card for a tapped node: what it says and which actions it offers, for a repeater you have
// as a contact or not, one never heard directly, one gone quiet, a person, a room and home.

private let now = Date(timeIntervalSince1970: 1_794_000_000)
private let homeAt = Position(latitude: 50.80, longitude: 19.10)
private let key = "a3" + String(repeating: "11", count: 31)

private func point(_ kind: MapContent.Point.Kind, contact: Bool, heard: Date? = nil) -> MapContent.Point {
    MapContent.Point(id: kind == .home ? "home" : key, name: "Góra", kind: kind,
                     position: kind == .home ? homeAt : Position(latitude: 50.90, longitude: 19.25), isContact: contact, lastHeard: heard)
}

private func summary(lastDirect: Date?, lastSeen: Date = now - 300, snr: Double? = 6.5) -> RepeaterAnalysis.Summary {
    RepeaterAnalysis.Summary(key: key, name: "Góra", type: .repeater, isContact: true, position: nil, km: nil,
                             relayed: 40, firstHop: 3, lastHop: 12, uncertainShare: 0, direct: lastDirect != nil, snrMedian: snr,
                             people: 3, nodes: 1, links: 2, lastSeen: lastSeen, lastDirect: lastDirect,
                             activity: [Int](repeating: 1, count: 17) + [4])
}

private func heard(hops: Int) -> HeardNode {
    HeardNode(key: key, name: "Ania", type: 1, latitude: 50.9, longitude: 19.25, firstHeard: now - 86400, lastHeard: now - 300,
              snr: -2.5, rssi: -110, hops: hops, path: "", hashSize: 1, count: 4)
}

@Suite("Map card")
struct NodeCardTests {
    @Test func yourRepeaterAsAContact() {
        let c = NodeCard(point: point(.repeater, contact: true), summary: summary(lastDirect: now - 120), heard: nil, home: homeAt,
                         isYours: true, quietSince: nil, now: now, idBytes: 1)
        #expect(c.id == "A3")
        #expect(c.subtitle == "Repeater · 15.3 km north-east")
        #expect(c.tags == ["Your repeater"])
        #expect(c.quiet == nil)
        #expect(c.stats.map(\.value) == ["2 min · +6.5 dB", "21", "3 · 2"])
        #expect(c.stats.map(\.label) == ["heard directly", "passed on, 3 h", "people · links"])
        #expect(c.primary == [.ping, .details, .links])
        #expect(c.menu == [.query, .adminLogin, .directions, .copyID, .copyPosition, .removeContact])
    }

    @Test func aRepeaterOnlyHeardInPaths() {
        let c = NodeCard(point: point(.repeater, contact: false), summary: summary(lastDirect: nil, snr: nil), heard: nil, home: homeAt,
                         isYours: false, quietSince: nil, now: now, idBytes: 2)
        #expect(c.id == "A311")   // as 2-byte paths show it
        #expect(c.tags == ["Not a contact"])
        #expect(c.stats.first == NodeCard.Stat(value: "via mesh", label: "seen 5 min"))
        // pinging needs no contact; adding one comes first in the menu, and there's nothing to remove
        #expect(c.primary == [.ping, .details, .links])
        #expect(c.menu.first == .addContact && !c.menu.contains(.removeContact) && !c.menu.contains(.adminLogin))
    }

    @Test func aRepeaterNeverInAPathShowsItsAdvert() {
        let c = NodeCard(point: point(.repeater, contact: false, heard: now - 3600), summary: nil, heard: nil, home: nil,
                         isYours: false, quietSince: nil, now: now)
        #expect(c.stats.isEmpty)
        #expect(c.subtitle == "Repeater · advert 1 h")
    }

    @Test func aRepeaterGoneQuiet() {
        let c = NodeCard(point: point(.repeater, contact: true), summary: summary(lastDirect: now - 3000), heard: nil, home: homeAt,
                         isYours: true, quietSince: now - 2900, now: now)
        #expect(c.quiet?.hasPrefix("Gone quiet since ") == true)
    }

    @Test func aPerson() {
        let direct = NodeCard(point: point(.person, contact: true), summary: nil, heard: heard(hops: 0), home: homeAt,
                              isYours: false, quietSince: nil, now: now)
        #expect(direct.stats.map(\.value) == ["direct", "-2.5 dB", "5 min"])
        #expect(direct.stats.map(\.label) == ["heard", "signal", "advert heard"])
        #expect(direct.primary == [.message, .route])
        #expect(!direct.subtitle.contains("advert"))   // the stats say it
        let far = NodeCard(point: point(.person, contact: false), summary: nil, heard: heard(hops: 3), home: homeAt,
                           isYours: false, quietSince: nil, now: now)
        #expect(far.stats.map(\.label) == ["hops", "last-hop signal", "advert heard"])
        #expect(far.primary == [.addContact])
        #expect(far.tags == ["Not a contact"])
    }

    @Test func aRoom() {
        let joined = NodeCard(point: point(.room, contact: true), summary: nil, heard: heard(hops: 1), home: homeAt,
                              isYours: false, quietSince: nil, now: now)
        #expect(joined.primary == [.openRoom, .details])
        #expect(joined.stats.map(\.label) == ["hop", "last-hop signal", "advert heard"])
        let relaying = NodeCard(point: point(.room, contact: false), summary: summary(lastDirect: now - 60), heard: heard(hops: 1), home: homeAt,
                                isYours: false, quietSince: nil, now: now)
        #expect(relaying.primary == [.addContact, .details])
        #expect(relaying.stats.map(\.label).contains("passed on, 3 h"))
    }

    @Test func yourHome() {
        let c = NodeCard(point: point(.home, contact: false), summary: nil, heard: nil, home: homeAt, isYours: false, quietSince: nil,
                         directRepeaters: 3, now: now)
        #expect(c.id == nil)
        #expect(c.tags.isEmpty)
        #expect(c.subtitle == "Your home location · 50.80000, 19.10000")
        #expect(c.stats == [NodeCard.Stat(value: "3", label: "repeaters heard directly, 1 h")])
        #expect(c.primary == [.changeHome, .offlineMaps])
        #expect(c.menu == [.copyPosition])
    }

    @Test func agesReadShort() {
        #expect(NodeCard.ago(now - 30, now: now) == "now")
        #expect(NodeCard.ago(now - 600, now: now) == "10 min")
        #expect(NodeCard.ago(now - 7200, now: now) == "2 h")
        #expect(NodeCard.ago(now - 3 * 86400, now: now) == "3 d")
        #expect(NodeCard.ago(now + 60, now: now) == "now")   // a clock ahead
    }
}
