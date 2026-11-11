import Foundation
import Testing
@testable import MeshChatCore
import MeshCoreKit

// Tidying the radio's contact list: what goes, what always stays, and in what order.

@Suite("Tidying contacts")
struct ContactTidyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86400.0
    /// repeaters and sensors not heard for a month, however far
    let month = ContactTidy.Options(kinds: [.repeater, .sensor], age: .month)

    func contact(_ n: UInt8, _ type: NodeType, _ name: String, modified daysAgo: Double? = nil, favourite: Bool = false) -> Contact {
        Contact(key: PublicKey(Data([n]) + Data(repeating: 0x5A, count: 31))!, type: type, flags: favourite ? 1 : 0, name: name,
                lastModified: daysAgo.map { UInt32(now.timeIntervalSince1970 - $0 * day) } ?? 0)
    }

    @Test func removesOldRepeatersAndSensorsOldestFirst() {
        let list = [
            contact(1, .repeater, "Fresh RPT", modified: 2),
            contact(2, .repeater, "Old RPT", modified: 40),
            contact(3, .repeater, "Older RPT", modified: 90),
            contact(4, .sensor, "Old sensor", modified: 35),
            contact(5, .repeater, "Never heard"),
            contact(6, .companion, "Ania", modified: 200),
            contact(7, .room, "Old room", modified: 100),
        ]
        let t = ContactTidy(contacts: list, lastHeard: [:], messaged: [], joinedRooms: [], yourRepeater: nil, options: month, now: now)
        #expect(t.remove.map(\.name) == ["Never heard", "Older RPT", "Old RPT", "Old sensor"])
        #expect(t.kept == [.heardLately: 1, .otherKind: 2])   // people and rooms aren't touched by default
        #expect(t.keptCount == 3 && t.total == 7)
        #expect(t.actionTitle == "Remove 4 contacts")
    }

    @Test func alwaysKeepsFavouritesRoomsChatsAndYourRepeater() {
        let fav = contact(1, .repeater, "Fav RPT", modified: 60, favourite: true)
        let mine = contact(2, .repeater, "My RPT", modified: 60)
        let room = contact(3, .room, "Luna", modified: 60)
        let friend = contact(4, .companion, "Ania", modified: 60)
        let stranger = contact(5, .companion, "Someone", modified: 60)
        let all = ContactTidy.Options(kinds: [.repeater, .sensor, .room, .companion], age: .any)
        let t = ContactTidy(contacts: [fav, mine, room, friend, stranger], lastHeard: [:], messaged: [friend.key.hex],
                            joinedRooms: [room.key.hex], yourRepeater: mine.key.hex, options: all, now: now)
        #expect(t.remove.map(\.name) == ["Someone"])
        #expect(t.kept == [.favourite: 1, .yourRepeater: 1, .joinedRoom: 1, .messaged: 1])
        #expect(t.actionTitle == "Remove 1 person")
    }

    @Test func theAppsOwnHearingCounts() {
        // the radio last updated it long ago, but the app heard it yesterday
        let r = contact(1, .repeater, "RPT", modified: 50)
        let t = ContactTidy(contacts: [r], lastHeard: [r.key.hex: now - day], messaged: [], joinedRooms: [],
                            yourRepeater: nil, options: ContactTidy.Options(kinds: [.repeater], age: .week), now: now)
        #expect(t.remove.isEmpty && t.kept == [.heardLately: 1])
        #expect(t.actionTitle == "Nothing to remove")
        // an advert time in the future (a node with a wrong clock) doesn't count as heard
        var future = contact(2, .repeater, "Clock RPT", modified: 50)
        future.lastAdvert = UInt32(now.timeIntervalSince1970 + 365 * day)
        #expect(ContactTidy.lastHeard(future, app: nil, now: now) == now - 50 * day)
        #expect(ContactTidy.lastHeard(contact(3, .repeater, "X"), app: nil, now: now) == .distantPast)
    }

    @Test func farOnesGoWhenEverythingIsHeardLately() {
        // a busy mesh: every repeater advertised today, from 0 to 6 hops away
        let list = (0...6).map { contact(UInt8($0 + 1), .repeater, "RPT \($0) hops", modified: 0.1) } + [contact(9, .repeater, "Never in a path", modified: 0.1)]
        var hops: [String: Int] = [:]
        for (i, c) in list.prefix(7).enumerated() { hops[c.key.hex] = i }
        let t = ContactTidy(contacts: list, lastHeard: [:], hops: hops, messaged: [], joinedRooms: [], yourRepeater: nil,
                            options: .standard, now: now)
        #expect(t.remove.map(\.name).sorted() == ["RPT 4 hops", "RPT 5 hops", "RPT 6 hops"])
        #expect(t.kept == [.near: 4, .distanceUnknown: 1])   // how far the last one is isn't known: it stays
        // a month's age filter on the same mesh removes nothing: that's what the distance is for
        #expect(ContactTidy(contacts: list, lastHeard: [:], hops: hops, messaged: [], joinedRooms: [], yourRepeater: nil,
                            options: month, now: now).remove.isEmpty)
    }

    @Test func repeatersOnlyNamesThem() {
        let t = ContactTidy(contacts: [contact(1, .repeater, "A", modified: 40), contact(2, .repeater, "B", modified: 50)],
                            lastHeard: [:], messaged: [], joinedRooms: [], yourRepeater: nil, options: month, now: now)
        #expect(t.actionTitle == "Remove 2 repeaters")
        #expect(t.remove.map(\.name) == ["B", "A"])
    }

    @Test func nodesListFilters() {
        let contactKey = PublicKey(Data([1]) + Data(repeating: 0x5A, count: 31))!
        let fresh = contact(1, .repeater, "Fresh", modified: 2)
        let heardOnly = HeardNode(key: "02" + String(repeating: "5a", count: 31), name: "Heard", type: 2, firstHeard: now - 90 * day,
                                  lastHeard: now - 40 * day, snr: 5, rssi: -90, hops: 1, path: "", hashSize: 1, count: 3)
        let rows = NodeRow.all(contacts: [fresh], heard: [heardOnly], home: nil, now: now)
        func names(_ show: NodeRow.Show, _ hide: Bool) -> [String] { rows.filter { $0.shown(show, hideStale: hide, now: now) }.map(\.name).sorted() }
        #expect(names(.all, false) == ["Fresh", "Heard"])
        #expect(names(.contacts, false) == ["Fresh"])
        #expect(names(.heardOnly, false) == ["Heard"])
        #expect(names(.all, true) == ["Fresh"])          // heard 40 days ago
        #expect(names(.heardOnly, true).isEmpty)
        #expect(rows.contains(where: { $0.contact?.key == contactKey }))
    }

    @Test func autoAddReachAsTheRadioCountsIt() {
        // the radio's 1 is "heard directly", N is up to N−1 hops (firmware NodePrefs.h)
        #expect([0, 1, 2, 4].map { AutoAddConfig(flags: 0, maxHops: $0).reachText } == ["Any distance", "Direct only", "Up to 1 hop", "Up to 3 hops"])
        #expect(AutoAddConfig.maxHops(forReach: 3) == 4 && AutoAddConfig(flags: 0, maxHops: 4).reachHops == 3)
        #expect(AutoAddConfig.maxHops(forReach: 100) == 64)
    }

    @Test func clearingEverything() {
        let fav = contact(1, .repeater, "Fav", modified: 50, favourite: true)
        let list = [contact(2, .companion, "Ania", modified: 1), fav, contact(3, .room, "Luna", modified: 30), contact(4, .repeater, "Never")]
        // people and rooms too, longest unheard first; favourites only if asked to keep them
        #expect(ContactTidy.everything(list, lastHeard: [:], keepFavourites: true, now: now).map(\.name) == ["Never", "Luna", "Ania"])
        #expect(ContactTidy.everything(list, lastHeard: [:], keepFavourites: false, now: now).map(\.name) == ["Never", "Fav", "Luna", "Ania"])
    }

    @Test func fullness() {
        #expect(ContactTidy.fullness(count: 344, max: 350) == ("344 of 350", true))
        #expect(ContactTidy.fullness(count: 300, max: 350) == ("300 of 350", false))
        #expect(ContactTidy.fullness(count: 0, max: 0).nearlyFull == false)
    }
}
