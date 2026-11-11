import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// The logic behind the screens: message details, the rooms browser, the nodes list, the map, settings.

private func key(_ first: UInt8, _ fill: UInt8) -> PublicKey { PublicKey(Data([first]) + Data(repeating: fill, count: 31))! }

@Suite("Message details")
struct MessageDetailTests {
    @Test func copiesAreListedInTheOrderHeard() throws {
        let store = try Store.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_794_000_000)
        func packet(_ path: String, after s: Double, snr: Double, fp: Int64 = 77) -> PacketRecord {
            PacketRecord(date: t0 + s, route: "flood", type: "GRP_TXT", hops: path.count / 2, path: path, hashSize: 1, snr: snr, rssi: -90,
                         fingerprint: fp, raw: Data([0x15, 0]))
        }
        _ = try store.insert(packet("394e", after: 0, snr: 5))
        _ = try store.insert(packet("39", after: 0.8, snr: 7.5))
        _ = try store.insert(packet("394e", after: 1.5, snr: 4))
        _ = try store.insert(packet("77", after: 2, snr: 1, fp: 99))   // another packet
        var m = Message(date: t0 + 0.1, senderTimestamp: 1_793_999_990, conversation: .channel(0), direction: .incoming, sender: "Ala",
                        text: "hej", status: .received, hops: 2, path: "394e")
        m.fingerprint = 77
        m = try store.insert(m)

        let info = MessageInfo(message: m, store: store)
        #expect(info.copies.map(\.packet.path) == ["394e", "39", "394e"])
        #expect(zip(info.copies.map(\.after), [0, 0.8, 1.5]).allSatisfy { abs($0 - $1) < 0.002 })
        #expect(info.routes == 2)
        #expect(abs((info.clockSkew ?? 0) - 10.1) < 0.001)   // the sender's clock 10 s behind

        var none = m
        none.fingerprint = nil
        #expect(MessageInfo(message: none, store: store).copies.isEmpty)
    }
}

@Suite("Rooms browser")
struct RoomsBrowserTests {
    let home = Position(latitude: 50.81, longitude: 19.12)

    func heard(_ k: PublicKey, _ name: String, type: NodeType, lat: Double?, lon: Double?) -> HeardNode {
        HeardNode(key: k.hex, name: name, type: Int(type.rawValue), latitude: lat, longitude: lon, firstHeard: .now, lastHeard: .now,
                  snr: 5, rssi: -90, hops: 2, path: "394e", hashSize: 1, count: 3)
    }

    @Test func joinedFirstThenNearestAndOnlyRooms() {
        let luna = Contact(key: key(0x10, 1), type: .room, name: "LUNA", position: Position(latitude: 50.0, longitude: 19.9))   // ~108 km
        let near = Contact(key: key(0x11, 2), type: .room, name: "Near room", position: Position(latitude: 50.80, longitude: 19.20))
        let person = Contact(key: key(0x12, 3), type: .companion, name: "Ala")
        let heardOnly = heard(key(0x13, 4), "Heard room", type: .room, lat: 50.5, lon: 19.5)
        let heardPerson = heard(key(0x14, 5), "Bob", type: .companion, lat: nil, lon: nil)
        let rooms = [luna.key.hex: RoomMembership(key: luna.key.hex, joined: .now, loginAt: .now, left: false, role: "guest", admin: false)]

        let list = RoomEntry.all(contacts: [luna, near, person], heard: [heardOnly, heardPerson], rooms: rooms, conversations: [:], home: home)
        #expect(list.map(\.name) == ["LUNA", "Near room", "Heard room"])
        #expect(list[0].isMember && !list[1].isMember)
        #expect(list[2].contact == nil && list[2].heard != nil)
        #expect(list[1].bearing == "east")
        #expect(abs((list[0].km ?? 0) - 108) < 3)
    }

    @Test func postsFromAnotherAppCountAsJoinedUntilLeft() {
        let r = Contact(key: key(0x20, 6), type: .room, name: "Room")
        let conv: [ConversationID: ConversationSummary] = [.direct(r.key): ConversationSummary(conversation: .direct(r.key), lastID: 5, count: 4, lastDate: .now)]
        #expect(RoomEntry.all(contacts: [r], heard: [], rooms: [:], conversations: conv, home: nil).first?.isMember == true)
        let left = [r.key.hex: RoomMembership(key: r.key.hex, left: true, admin: false)]
        let entry = RoomEntry.all(contacts: [r], heard: [], rooms: left, conversations: conv, home: nil).first
        #expect(entry?.isMember == false && entry?.posts == 4)
    }

    @Test func rolesSayWhatYouCanDo() {
        #expect(RoomRole.label("read-write") == "Member" && RoomRole.label(nil) == "Joined")
        #expect(RoomRole.canPost("read-write") && RoomRole.canPost("admin") && RoomRole.canPost(nil))
        #expect(!RoomRole.canPost("guest") && !RoomRole.canPost("read-only"))
    }
}

@Suite("Nodes list")
struct NodeListTests {
    let home = Position(latitude: 50.81, longitude: 19.12)

    @Test func contactsAndHeardNodesMergeSortAndFilter() {
        let now = Date()
        let ala = Contact(key: key(0x01, 1), type: .companion, outPath: OutPath(hashSize: 1, hops: [Data([0x39]), Data([0x4e])]), name: "Ala",
                          lastAdvert: UInt32(now.timeIntervalSince1970 - 7200), position: Position(latitude: 50.9, longitude: 19.1))
        let rep = Contact(key: key(0x02, 2), type: .repeater, name: "Żarki RPT", position: Position(latitude: 50.62, longitude: 19.37))
        let heardRep = HeardNode(key: rep.key.hex, name: rep.name, type: 2, latitude: nil, longitude: nil, firstHeard: now - 9000,
                                 lastHeard: now - 60, snr: 8.5, rssi: -80, hops: 0, path: "", hashSize: 1, count: 12)
        let stranger = HeardNode(key: key(0x03, 3).hex, name: "Zenek", type: 1, latitude: 52.2, longitude: 21.0, firstHeard: now - 600,
                                 lastHeard: now - 600, snr: 2, rssi: -110, hops: 3, path: "394e77", hashSize: 1, count: 1)

        let all = NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home)
        #expect(all.map(\.name) == ["Żarki RPT", "Zenek", "Ala"])          // last heard first
        #expect(all[0].contact != nil && all[0].heard?.snr == 8.5 && all[0].hops == 0)
        #expect(all[1].contact == nil && all[1].type == .companion)
        #expect(all[2].hops == 2)                                          // the saved route's length

        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home, sort: .distance).map(\.name) == ["Ala", "Żarki RPT", "Zenek"])
        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home, sort: .hops).map(\.name) == ["Żarki RPT", "Ala", "Zenek"])
        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home, sort: .name).map(\.name) == ["Ala", "Żarki RPT", "Zenek"])
        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home, type: .repeater).map(\.name) == ["Żarki RPT"])
        // case-insensitive, accents ignored
        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: home, query: "zark").map(\.name) == ["Żarki RPT"])
        #expect(NodeRow.all(contacts: [ala, rep], heard: [heardRep, stranger], home: nil).allSatisfy { $0.km == nil })
    }
}

@Suite("Nodes list: clocks")
struct NodeClockTests {
    @Test func aNodeWithItsClockAheadDoesntSortFirst() {
        let now = Date(timeIntervalSince1970: 1_794_300_000)
        let ahead = Contact(key: key(0x51, 1), type: .repeater, name: "Clock ahead", lastAdvert: UInt32(now.timeIntervalSince1970 + 5 * 86400))
        let aheadButUpdated = Contact(key: key(0x52, 2), type: .repeater, name: "Updated", lastAdvert: UInt32(now.timeIntervalSince1970 + 86400),
                                      lastModified: UInt32(now.timeIntervalSince1970 - 600))
        let normal = Contact(key: key(0x53, 3), type: .repeater, name: "Normal", lastAdvert: UInt32(now.timeIntervalSince1970 - 3600))
        let rows = NodeRow.all(contacts: [ahead, aheadButUpdated, normal], heard: [], home: nil, now: now)
        #expect(rows.map(\.name) == ["Updated", "Normal", "Clock ahead"])
        #expect(rows[0].lastSeen == now - 600)   // the radio's own time for it
        #expect(rows[2].lastSeen == nil)           // a time still to come isn't believed
    }
}

@Suite("Map")
struct MapContentTests {
    @Test func pointsFromContactsHeardAndHome() {
        let home = Position(latitude: 50.81, longitude: 19.12)
        let rep = Contact(key: key(0x39, 1), type: .repeater, name: "A", position: Position(latitude: 50.7, longitude: 19.2))
        let nowhere = Contact(key: key(0x40, 2), type: .companion, name: "No position")
        let heardRoom = HeardNode(key: key(0x41, 3).hex, name: "Room", type: 3, latitude: 50.5, longitude: 19.5, firstHeard: .now, lastHeard: .now,
                                  snr: 3, rssi: -100, hops: 1, path: "39", hashSize: 1, count: 1)
        // a contact without a position takes the one from its heard advert
        let heardPerson = HeardNode(key: nowhere.key.hex, name: nowhere.name, type: 1, latitude: 50.6, longitude: 19.0, firstHeard: .now,
                                    lastHeard: .now, snr: 3, rssi: -100, hops: 1, path: "39", hashSize: 1, count: 1)
        let points = MapContent(contacts: [rep, nowhere], heard: [heardRoom, heardPerson], home: home).points
        let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        #expect(points.count == 4)
        #expect(byID[rep.key.hex]?.kind == .repeater && byID[rep.key.hex]?.isContact == true)
        #expect(byID[heardRoom.key]?.kind == .room && byID[heardRoom.key]?.isContact == false)
        #expect(byID[nowhere.key.hex]?.position == Position(latitude: 50.6, longitude: 19.0))
        #expect(byID["home"]?.kind == .home)
        #expect(MapContent(contacts: [nowhere], heard: [], home: nil).points.isEmpty)
    }

    @Test func aMessagesRouteRunsFromTheSenderToHome() {
        let home = Position(latitude: 50.81, longitude: 19.12)
        let a = Contact(key: key(0x39, 1), type: .repeater, name: "A", position: Position(latitude: 50.7, longitude: 19.2))
        let b = Contact(key: key(0x4e, 2), type: .repeater, name: "B")   // no position: not drawn, counted
        let c = Contact(key: key(0x77, 3), type: .repeater, name: "C", position: Position(latitude: 50.3, longitude: 19.8))
        let ala = Contact(key: key(0xa1, 4), type: .companion, name: "Ala", position: Position(latitude: 50.1, longitude: 20.0))
        let dir = NodeDirectory(contacts: [a, b, c, ala], heard: [], home: home)
        let m = Message(senderTimestamp: 1, conversation: .channel(0), direction: .incoming, sender: "Ala", text: "x", status: .received,
                        hops: 3, path: "774e39")
        let r = MapRoute.of(m, directory: dir, sender: ala)
        #expect(r.positions == [ala.position!, c.position!, a.position!, home])
        #expect(r.stops.first?.kind == .person && r.stops.last?.kind == .home)
        #expect(r.hops == 3 && r.hidden == 1 && r.isDrawable)
        #expect(r.summary == "Ala → C → A → You")
        #expect(r.title == "Ala → you")

        // the sender's position unknown: from the first repeater that has one
        #expect(MapRoute.of(m, directory: dir, sender: nil).positions == [c.position!, a.position!, home])
        // nothing placed but home: nothing to draw
        let lost = Message(senderTimestamp: 1, conversation: .channel(0), direction: .incoming, sender: "Ola", text: "x", status: .received,
                           hops: 1, path: "4e")
        #expect(!MapRoute.of(lost, directory: dir, sender: nil).isDrawable)
    }

    @Test func yourMessagesRouteStartsAtHome() {
        let home = Position(latitude: 50.81, longitude: 19.12)
        let a = Contact(key: key(0x39, 1), type: .repeater, name: "A", position: Position(latitude: 50.7, longitude: 19.2))
        let dir = NodeDirectory(contacts: [a], heard: [], home: home)
        let m = Message(senderTimestamp: 1, conversation: .channel(0), direction: .outgoing, sender: nil, text: "x", status: .repeated,
                        hops: 1, path: "39")
        let r = MapRoute.of(m, directory: dir, sender: nil)
        #expect(r.positions == [home, a.position!] && r.title == "Your message")
    }

    @Test func nearbyMarkersClusterUntilZoomedIn() {
        func point(_ id: String, _ lat: Double, _ lon: Double, _ kind: MapContent.Point.Kind = .repeater) -> MapContent.Point {
            MapContent.Point(id: id, name: id, kind: kind, position: Position(latitude: lat, longitude: lon), isContact: true, lastHeard: nil)
        }
        let points = [point("a", 50.300, 19.000), point("b", 50.301, 19.001), point("c", 50.302, 19.002, .person),
                      point("far", 52.2, 21.0), point("home", 50.3005, 19.0005, .home)]

        let wide = MapClustering.marks(points, zoom: 8)
        let clusters = wide.compactMap { if case .cluster(let c) = $0 { c } else { nil } }
        #expect(clusters.count == 1)
        let c = clusters[0]
        #expect(c.count == 3 && c.kind == .repeater)
        #expect(c.south == 50.300 && c.north == 50.302 && c.west == 19.000 && c.east == 19.002)
        // home is never folded in; the far one stands alone
        #expect(Set(wide.map(\.id)).isSuperset(of: ["home", "far"]))
        #expect(wide.count == 3)

        // the one you picked stays out of its cluster
        let picked = MapClustering.marks(points, zoom: 8, apart: ["a"])
        #expect(picked.contains(.point(points[0])))
        #expect(picked.compactMap { if case .cluster(let c) = $0 { c.count } else { nil } } == [2])

        // close enough in: every marker on its own
        #expect(MapClustering.marks(points, zoom: 14).count == points.count)
        // cluster IDs depend on the zoom, so a map never mistakes one level's cluster for another's
        #expect(MapClustering.marks(points, zoom: 9).compactMap { if case .cluster(let c) = $0 { c.id } else { nil } }.allSatisfy { $0.hasPrefix("cluster-9-") })
    }

    @Test func offlineDownloadsAreBounded() {
        let home = Position(latitude: 50.81, longitude: 19.12)
        #expect(OfflineRegion.around(home, radiusKm: 150, name: "big", maxZoom: 14).tileCount <= OfflineRegion.maxTiles)
        #expect(OfflineRegion.around(home, radiusKm: 50, name: "home", maxZoom: 13).estimatedBytes < 100_000_000)
        #expect(OfflineRegion(name: "Poland", south: 49, west: 14, north: 55, east: 24.2, maxZoom: 14).tileCount > OfflineRegion.maxTiles)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func coordinatesAsPeoplePasteThem() {
        let warsaw = Position(latitude: 52.2297, longitude: 21.0122)
        #expect(Geo.parseCoordinates("52.2297, 21.0122") == warsaw)
        #expect(Geo.parseCoordinates("  52,2297 21,0122 ") == warsaw)
        #expect(Geo.parseCoordinates("52.2297;21.0122") == warsaw)
        #expect(Geo.parseCoordinates("https://www.google.com/maps/@52.2297,21.0122,15z") == warsaw)
        #expect(Geo.parseCoordinates("https://maps.apple.com/?ll=52.2297,21.0122&q=Home") == warsaw)
        #expect(Geo.parseCoordinates("-33.8688, 151.2093") == Position(latitude: -33.8688, longitude: 151.2093))
        #expect(Geo.parseCoordinates("95, 10") == nil)
        #expect(Geo.parseCoordinates("Częstochowa") == nil)
    }

    @Test func radioParametersTheRadioAccepts() {
        let south = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)
        #expect(south.isValid)
        #expect(south.summary == "869.618 MHz · 62.5 kHz · SF6 · CR8")
        var r = south
        r.frequencyMHz = 100; #expect(r.problem?.contains("frequency") == true)
        r = south; r.spreadingFactor = 13; #expect(!r.isValid)
        r = south; r.codingRate = 4; #expect(!r.isValid)
        r = south; r.bandwidthKHz = 600; #expect(!r.isValid)
        #expect(RadioSettings.bandwidths.contains(62.5) && RadioSettings.bandwidths.contains(125))
    }

    @Test func bluetoothPins() {
        #expect(BluetoothPin("123456")?.value == 123456)
        #expect(BluetoothPin("012345") == nil)    // can't start with 0
        #expect(BluetoothPin("12345") == nil)
        #expect(BluetoothPin("1234567") == nil)
        #expect(BluetoothPin("12a456") == nil)
        #expect(BluetoothPin("١٢٣٤٥٦") == nil)   // digits, but not ASCII ones
        #expect(Codec.setDevicePin(654321).hex == "25f1fb0900")
    }
}

@Suite("Admin commands")
struct AdminCommandTests {
    @Test func theCatalogue() {
        #expect(AdminCommand.all.count == 116)
        // nothing the firmware takes only over serial (log start/stop/erase work remotely; reading it doesn't),
        // and not region load, which waits for a blank line
        for serial in ["erase", "log", "stats-packets", "stats-radio", "stats-core", "get acl", "get prv.key"] {
            #expect(!AdminCommand.all.contains { $0.command == serial }, "\(serial)")
        }
        #expect(!AdminCommand.all.contains { $0.command.hasPrefix("set freq") || $0.command.hasPrefix("region load") })
        #expect(Set(AdminCommand.all.map(\.command)).count == AdminCommand.all.count)
        #expect(AdminCommand.matching("reboot")?.confirm != nil)
        #expect(AdminCommand.matching("set radio 869.618,62.5,6,8")?.label == "Set radio")
        #expect(AdminCommand.matching("set radio 869.618,62.5,6,8")?.confirm != nil)
        #expect(AdminCommand.matching("get name")?.confirm == nil)
        #expect(AdminCommand.matching("rebootnow") == nil)
        #expect(AdminCommand.groups.first == "Actions")
        // every setting can be read
        for s in AdminSetting.all { #expect(AdminCommand.all.contains { $0.command == "get \(s.name)" }, "get \(s.name)") }
    }

    @Test func answersPairWithTheirCommands() {
        func cmd(_ id: Int, _ t: String, _ s: ConsoleLine.Status = .sent) -> ConsoleLine { ConsoleLine(id: id, isCommand: true, status: s, text: t) }
        func ans(_ id: Int, _ t: String) -> ConsoleLine { ConsoleLine(id: id, isCommand: false, status: .received, text: t) }
        let lines = [cmd(1, "get name"), cmd(2, "reboot", .failed), cmd(3, "get tx"), ans(4, "> North RPT"), ans(5, "> 22"),
                     cmd(6, "set tx 20"), ans(7, "OK"), cmd(8, "set repeat off"), ans(9, "Error: unsupported")]
        let a = AdminConsole.answers(lines)
        #expect(a[1]?.text == "> North RPT" && a[3]?.text == "> 22" && a[2] == nil)   // a command that wasn't sent gets no answer
        let v = AdminConsole.values(lines)
        #expect(v == ["name": "North RPT", "tx": "20"])   // the accepted set wins; a refused one changes nothing
    }

    @Test func secretsAreMasked() {
        #expect(AdminConsole.masked("set guest.password abc") == "set guest.password \u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(AdminConsole.masked("set prv.key 0011") == "set prv.key \u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(AdminConsole.masked("get guest.password") == "get guest.password")
        #expect(AdminConsole.masked("set name Fred") == "set name Fred")
    }
}
