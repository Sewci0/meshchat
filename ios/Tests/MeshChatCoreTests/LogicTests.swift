import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// Reference values: the web app's formulas run in Python (airtime, tile counts), and real geography.

@Suite("Geography")
struct GeoTests {
    let czestochowa = Position(latitude: 50.8118, longitude: 19.1203)
    let krakow = Position(latitude: 50.0647, longitude: 19.9450)

    @Test func distanceAndBearing() {
        #expect(abs(Geo.km(czestochowa, krakow) - 101.549) < 0.01)
        #expect(Geo.bearing(czestochowa, krakow) == "south-east")
        #expect(Geo.bearing(krakow, czestochowa) == "north-west")
    }

    @Test func pathsAreNamedNearestFirst() {
        // two repeaters share ID 39: the one near the next hop toward home is taken
        let near = Contact(key: PublicKey(hex: "39" + String(repeating: "01", count: 31))!, type: .repeater, name: "Near",
                           position: Position(latitude: 50.80, longitude: 19.10))
        let far = Contact(key: PublicKey(hex: "39" + String(repeating: "02", count: 31))!, type: .repeater, name: "Far",
                          position: Position(latitude: 54.35, longitude: 18.65))
        let b = Contact(key: PublicKey(hex: "4e" + String(repeating: "03", count: 31))!, type: .repeater, name: "B",
                        position: Position(latitude: 50.5, longitude: 19.4))
        let room = Contact(key: PublicKey(hex: "4e" + String(repeating: "04", count: 31))!, type: .room, name: "Room")
        let dir = NodeDirectory(contacts: [near, far, b, room], heard: [], home: czestochowa)
        let hops = dir.resolve(incoming: ["4e", "39"])   // origin first, you last
        #expect(hops.map(\.label) == ["B", "Near (?)"])   // repeaters beat rooms; 39 is ambiguous
        #expect(dir.resolve(outgoing: ["39", "4e"]).map { $0.node?.name } == ["Near", "B"])
        #expect(dir.resolve(incoming: ["ff"]).first?.label == "? ff")
        #expect(NodeDirectory.split("39004e63", hashSize: 2) == ["3900", "4e63"])
    }
}

@Suite("Packet anatomy")
struct AnatomyTests {
    @Test func channelPacketFields() throws {
        let raw = try #require(Data(hex: "1502394ed9e85abb980cfd3736422e1ba7fbbc7cad1b95e20d5eda9bc0c5700f426b8524e9ecc35f567777dc63ea35784e639aed1ad7b4"))
        let a = try #require(PacketAnatomy(raw: raw))
        #expect(a.fields.map(\.label) == ["Header", "Path length", "Path", "Channel ID", "MAC", "Ciphertext"])
        #expect(a.fields[0].note == "flood route · GRP_TXT · version 1")
        #expect(a.fields[3].hex == "d9")
        #expect(a.routing == 4)
        #expect(a.cipher == 48)
        #expect(a.total == raw.count)
        #expect(a.hops == ["39", "4e"])
    }

    @Test func airtimeMatchesTheWebApp() {
        let sf6 = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)
        let sf8 = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
        let sf12 = RadioSettings(frequencyMHz: 868, bandwidthKHz: 125, spreadingFactor: 12, codingRate: 5)
        #expect(abs(PacketAnatomy.airtimeMs(bytes: 74, sf6) - 260.352) < 0.001)
        #expect(abs(PacketAnatomy.airtimeMs(bytes: 74, sf8) - 803.84) < 0.001)
        #expect(abs(PacketAnatomy.airtimeMs(bytes: 20, sf12) - 1581.056) < 0.001)   // low data rate optimisation
    }
}

@Suite("QR links and presets")
struct LinkTests {
    let key = "f5032d01e6f0c55cfb1d938b404d1aec87ee335a5de946c06d6bdde7080c2dbc"

    @Test func contactLinksRoundTrip() throws {
        let made = MeshLink.contactLink(name: "Ala Kowalska", key: PublicKey(hex: key)!, type: .room)
        guard case .contact(let name, let k, let type)? = MeshLink(made) else { Issue.record("not parsed"); return }
        #expect(name == "Ala Kowalska" && k.hex == key && type == .room)
    }

    @Test func linksAsTheAppsWriteThem() {
        guard case .contact(let name, _, let type)? = MeshLink("meshcore://contact/add?name=yurasso+%F0%9F%93%A1&public_key=\(key.uppercased())&type=1")
        else { Issue.record("not parsed"); return }
        #expect(name == "yurasso 📡" && type == .companion)
        guard case .channel(let ch, let secret)? = MeshLink("meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72")
        else { Issue.record("not parsed"); return }
        #expect(ch == "Public" && secret.hex == "8b3387e9c5cdea6ac9e5edbaa115cd72")
    }

    @Test func badLinksAreRejected() {
        #expect(MeshLink("https://meshcore.io") == nil)
        #expect(MeshLink("meshcore://contact/add?name=x&public_key=1234&type=1") == nil)
        #expect(MeshLink("meshcore://contact/add?name=x&public_key=\(key)&type=9") == nil)
        #expect(MeshLink("meshcore://channel/add?name=&secret=8b3387e9c5cdea6ac9e5edbaa115cd72") == nil)
        #expect(MeshLink.fitName(String(repeating: "ż", count: 20)).utf8.count <= 31)
    }

    @Test func suggestedNetworksMatchTheRadio() {
        var store = RadioProfileStore()
        store.seedIfNeeded()
        #expect(store.match(RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8))?.name == "MeshCore Południe")
        #expect(store.match(RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8))?.name == "MeshCore Polska")
        #expect(store.match(RadioSettings(frequencyMHz: 868, bandwidthKHz: 125, spreadingFactor: 11, codingRate: 5)) == nil)
    }
}

@Suite("Delivery stats")
struct DeliveryTests {
    func dm(_ status: MessageStatus, ackTry: Int? = nil, tries: [Bool]? = nil, rtt: Int? = nil) -> Message {
        var m = Message(senderTimestamp: 1, conversation: .channel(0), direction: .outgoing, sender: "me", text: "x", status: status)
        m.ackTry = ackTry; m.triesFlood = tries; m.roundTripMs = rtt
        return m
    }

    @Test func outcomesAndMedians() {
        let s = DeliveryStats([
            dm(.delivered, ackTry: 1, tries: [false], rtt: 1000),
            dm(.delivered, ackTry: 2, tries: [false, false], rtt: 3000),
            dm(.delivered, ackTry: 3, tries: [false, false, true], rtt: 6000),
            dm(.noAck, tries: [false, false, true]),
            dm(.noAck),
            dm(.delivered),   // older: no detail
            dm(.sending),     // still going: not counted
        ])
        #expect(s.sent == 6 && s.delivered == 4 && s.firstTry == 1)
        #expect(s.onRoute == 2 && s.byFlood == 1 && s.noReceipt == 2)
        #expect(s.medianRoundTripOnRoute == 3000 && s.medianRoundTripByFlood == 6000)
        #expect(s.recentMisses == 2)
        #expect(DeliveryStats.outcome(dm(.delivered)) == .delivered)
    }
}

@Suite("Offline regions")
struct RegionTests {
    @Test func tileCountsMatchTheMaths() {
        #expect(OfflineRegion(name: "world", south: -85, west: -180, north: 85, east: 180, minZoom: 0, maxZoom: 0).tileCount == 1)
        #expect(OfflineRegion(name: "south", south: 50, west: 18.5, north: 51, east: 20, minZoom: 0, maxZoom: 14).tileCount == 6928)
        let r = OfflineRegion.around(Position(latitude: 50.0647, longitude: 19.9450), radiusKm: 50, name: "Kraków")
        #expect(r.contains(Position(latitude: 50.0647, longitude: 19.9450)))
        #expect(!r.contains(Position(latitude: 52.23, longitude: 21.01)))   // Warsaw
        #expect(abs((r.north - r.south) * 111.32 - 100) < 0.5)
    }
}

@Suite("Repeater analysis")
struct AnalysisTests {
    let home = Position(latitude: 50.80, longitude: 19.10)
    var a: Contact { Contact(key: PublicKey(hex: "39" + String(repeating: "aa", count: 31))!, type: .repeater, name: "A", position: Position(latitude: 50.81, longitude: 19.11)) }
    var b: Contact { Contact(key: PublicKey(hex: "4e" + String(repeating: "bb", count: 31))!, type: .repeater, name: "B", position: Position(latitude: 50.60, longitude: 19.40)) }
    var c: Contact { Contact(key: PublicKey(hex: "77" + String(repeating: "cc", count: 31))!, type: .repeater, name: "C", position: Position(latitude: 50.40, longitude: 19.80)) }

    /// a packet heard along `path`; copies of one packet share its fingerprint (by default each is its own)
    func packet(_ path: String, at d: Date, type: String = "GRP_TXT", snr: Double = 5, raw: Data = Data([0x15, 0]),
                fingerprint: Int64? = nil) -> PacketRecord {
        PacketRecord(date: d, route: "flood", type: type, hops: path.count / 2, path: path, hashSize: 1, snr: snr, rssi: -100,
                     fingerprint: fingerprint ?? Int64(d.timeIntervalSince1970 * 1000), raw: raw)
    }

    @Test func yoursOnlyWhenItPassesYoursOn() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b, c], heard: [], home: home)
        // heard straight from A a lot, but none of your messages seen passing through: no repeater is yours
        let packets = (0..<5).map { packet("39", at: now - 600 + Double($0) * 60) }
        #expect(RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now).yours == nil)
        // one of yours entered the mesh at B: B is yours, though A is heard more
        let r = RepeaterAnalysis(packets: packets, channelRoutes: [(sender: nil, path: "4e", hashSize: 1, date: now - 30)], directory: dir, now: now)
        #expect(r.yours?.key == b.key.hex && r.yours?.passed == 1)
    }

    @Test func aPacketHeardAlongSeveralPathsCountsOnce() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b, c], heard: [], home: home)
        // one of your messages: A passed it on first; you heard A, then B and C passing on A's copy
        let copies = [packet("39", at: now - 60, fingerprint: 42), packet("394e", at: now - 59, fingerprint: 42),
                      packet("3977", at: now - 58, fingerprint: 42)]
        let r = RepeaterAnalysis(packets: copies, channelRoutes: [(sender: nil, path: "39", hashSize: 1, date: now - 60)],
                                 directory: dir, now: now)
        let sA = r.summary(a.key.hex)
        #expect(sA.relayed == 1 && sA.firstHop == 1)   // not 3: one packet entered the mesh at A
        #expect(sA.lastHop == 1)                        // heard straight from A once
        #expect(r.summary(b.key.hex).relayed == 1 && r.summary(c.key.hex).relayed == 1)
        #expect(r.stats[a.key.hex]?.links[b.key.hex]?.to == 1 && r.stats[a.key.hex]?.links[c.key.hex]?.to == 1)
        #expect(r.yours?.passed == 1)                   // and it's one of yours, so the two agree
        #expect(r.stats[a.key.hex]?.recent.count == 1)
    }

    @Test func countsRelaysLinksAndYourRepeater() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b, c], heard: [], home: home)
        var packets = (0..<12).map { packet("774e39", at: now - 3600 + Double($0) * 60, snr: 7) }   // C → B → A → you
        packets.append(packet("4e39", at: now - 600))
        let routes = [(sender: Optional("Ala"), path: "774e39", hashSize: 1, date: now - 100),   // Ala entered at C
                      (sender: nil, path: "39", hashSize: 1, date: now - 50),                   // A passed on yours
                      (sender: nil, path: "39", hashSize: 1, date: now - 40)]
        let r = RepeaterAnalysis(packets: packets, channelRoutes: routes, directory: dir, now: now)
        let sA = r.summary(a.key.hex), sB = r.summary(b.key.hex), sC = r.summary(c.key.hex)
        #expect(sA.relayed == 13 && sA.lastHop == 13 && sA.direct && sA.snrMedian == 7)
        #expect(sB.relayed == 13 && sB.firstHop == 1 && !sB.direct)
        #expect(sC.firstHop == 12 && sC.people == 1)
        #expect(r.stats[c.key.hex]?.links[b.key.hex]?.to == 12)
        #expect(r.stats[a.key.hex]?.links[b.key.hex]?.from == 13)
        #expect(r.yours?.key == a.key.hex && r.yours?.passesYours == true && r.yours?.passed == 2)
        #expect(r.list.first?.relayed == 13)
        #expect(r.packetsCounted == 13)
        #expect(sA.km != nil)
    }

    @Test func aRepeaterThatWentQuiet() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b], heard: [], home: home)
        // A heard directly 20 times, then for the last hour only B: 30 packets
        var packets = (0..<20).map { packet("39", at: now - 7200 + Double($0) * 60, snr: 8) }
        packets += (0..<30).map { packet("4e", at: now - 3000 + Double($0) * 90, snr: 4) }
        let r = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now)
        let q = r.quiet(a.key.hex, now: now)
        #expect(q != nil)
        #expect(q?.missed == 30)
        #expect(q?.next?.key == b.key.hex)
        #expect(r.quiet(b.key.hex, now: now) == nil)   // still heard
    }

    @Test func mapLinksEndAtTheLinkedRepeaters() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b, c], heard: [], home: home)
        // C passes on to B, B to A: B links both, A and C only B
        let packets = (0..<4).map { packet("774e39", at: now - 600 + Double($0) * 60) }
        let r = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now)
        let linked = MapLinks.linked(from: b.key.hex, analysis: r)
        #expect(Set(linked) == [a.key.hex, c.key.hex])
        let lines = MapLinks.lines(from: b.key.hex, analysis: r)
        #expect(lines.count == linked.count)
        #expect(lines.map { $0.last! } == linked.compactMap { r.directory.nodes[$0]?.position })   // each line ends at one of them
        #expect(MapLinks.linked(from: a.key.hex, analysis: r) == [b.key.hex])
    }

    @Test func heardDirectlyTimesOutAfterAnHour() {
        let now = Date()
        func s(ago: Double?) -> RepeaterAnalysis.Summary {
            RepeaterAnalysis.Summary(key: "k", name: "k", type: .repeater, isContact: false, position: nil, km: nil, relayed: 1, firstHop: 0,
                                     lastHop: ago == nil ? 0 : 1, uncertainShare: 0, direct: ago != nil, snrMedian: nil, people: 0, nodes: 0,
                                     links: 0, lastSeen: now, lastDirect: ago.map { now - $0 }, activity: [])
        }
        #expect(s(ago: 60).heardDirectly(now: now))
        #expect(s(ago: 59 * 60).heardDirectly(now: now))
        #expect(!s(ago: 61 * 60).heardDirectly(now: now))   // heard directly once, not lately: further along now
        #expect(!s(ago: nil).heardDirectly(now: now))
    }

    @Test func yoursFollowsYourLatestMessages() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b, c], heard: [], home: home)
        // three of yours through A two days ago, one through C yesterday, then two through B today
        let mine: [(String, Double)] = [("39", 2 * 86400 + 300), ("39", 2 * 86400 + 200), ("39", 2 * 86400 + 100), ("77", 86400), ("4e", 600), ("4e", 60)]
        let routes = mine.map { (sender: String?.none, path: $0.0, hashSize: 1, date: now - $0.1) }
        let r = RepeaterAnalysis(packets: [], channelRoutes: routes, directory: dir, now: now)
        #expect(r.yours?.key == b.key.hex)   // the last 5: B, B, C, A, A: B and A tie, B is the latest
        #expect(r.yours?.passed == 2)
        // across the period alone A would have won (3 against 2)
        #expect(r.stats[a.key.hex]?.heardYou == 3)
    }

    @Test func heardDirectlyFreshestThenStrongest() {
        let now = Date()
        func s(_ name: String, ago: Double?, snr: Double) -> RepeaterAnalysis.Summary {
            var x = RepeaterAnalysis.Summary(key: name, name: name, type: .repeater, isContact: false, position: nil, km: nil,
                                             relayed: 1, firstHop: 0, lastHop: ago == nil ? 0 : 1, uncertainShare: 0, direct: ago != nil,
                                             snrMedian: snr, people: 0, nodes: 0, links: 0, lastSeen: now,
                                             lastDirect: ago.map { now - $0 }, activity: [])
            x.recentSnr = snr
            return x
        }
        let list = [s("old strong", ago: 2 * 86400, snr: 9), s("live weak", ago: 60, snr: -3), s("recent", ago: 600, snr: 5),
                    s("live strong", ago: 120, snr: 7), s("old weak", ago: 86400, snr: -6), s("via mesh", ago: nil, snr: 12)]
        let ordered = list.sorted { RepeaterAnalysis.Summary.freshestStrongest($0, $1, now: now) }.map(\.name)
        #expect(ordered == ["live strong", "live weak", "recent", "old strong", "old weak", "via mesh"])
    }

    @Test func recentSignalIsTheMedianOfTheLastPacketsHeardDirectly() {
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b], heard: [], home: home)
        // twelve packets straight from A, 0 to 11 dB, oldest first, and one through A to B (B heard directly)
        var packets = (0..<12).map { packet("39", at: now - 3600 + Double($0) * 60, snr: Double($0)) }
        packets.append(packet("394e", at: now - 30, snr: 9))
        let r = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now)
        #expect(r.summary(a.key.hex).recentSnr == 7)   // the last ten (2…11): their median, not the period's
        #expect(r.summary(b.key.hex).recentSnr == 9)
        #expect(r.summary("ff").recentSnr == nil)
    }

    @Test func oldEvidenceIsNotQuietNow() {
        // A heard directly, then traffic through B two days ago, then nothing logged (MeshChat wasn't
        // connected) until a few packets just now: that says nothing about A today
        let now = Date()
        let dir = NodeDirectory(contacts: [a, b], heard: [], home: home)
        var packets = (0..<20).map { packet("39", at: now - 2 * 86400 - 7200 + Double($0) * 60, snr: 8) }
        packets += (0..<100).map { packet("4e", at: now - 2 * 86400 + Double($0) * 30, snr: 4) }
        packets += (0..<2).map { packet("4e", at: now - 60 + Double($0) * 20, snr: 4) }
        #expect(RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now).quiet(a.key.hex, now: now) == nil)
        // once enough traffic arrives again without A, it's quiet, with the date it was last heard
        packets += (0..<30).map { packet("4e", at: now - 3000 + Double($0) * 90, snr: 4) }
        let q = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, now: now).quiet(a.key.hex, now: now)
        #expect(q != nil && q?.missed == 32)
        #expect(q.map { now.timeIntervalSince1970 - $0.since.timeIntervalSince1970 > 86400 } == true)
    }
}
