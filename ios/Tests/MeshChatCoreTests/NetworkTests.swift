import Foundation
import Testing
@testable import MeshChatCore
import MeshCoreKit

// Following the radio's network: naming networks, what each one heard, keeping heard nodes per network
// (and moving the old records), and where a conversation shows the network changed.

@Suite("Networks")
struct NetworkTests {
    let south = "869.618/62.5/6", national = "869.618/62.5/8"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func key(_ n: UInt8) -> String { String(format: "%02x", n) + String(repeating: "5a", count: 31) }

    func node(_ n: UInt8, _ network: String, minutesAgo: Double, hops: Int = 1, name: String? = nil) -> HeardNode {
        HeardNode(key: key(n), name: name ?? "Node \(n)", type: 2, firstHeard: now - 86400, lastHeard: now - minutesAgo * 60,
                  snr: 5, rssi: -90, hops: hops, path: "", hashSize: 1, count: 1, network: network)
    }

    @Test func keysAndNames() {
        let k = NetworkKey(RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 5))
        #expect(k.key == south)
        #expect(NetworkKey(south)?.key == south)
        #expect(NetworkKey("nonsense") == nil)
        var profiles = RadioProfileStore()
        profiles.seedIfNeeded()
        #expect(profiles.name(forNetwork: south) == "MeshCore Południe")   // whatever the coding rate
        #expect(profiles.name(forNetwork: national) == "MeshCore Polska")
        #expect(profiles.name(forNetwork: "868.000/125/9") == "868.000 MHz · 125 kHz · SF9")
    }

    @Test func whatEachNetworkHeard() {
        let all = [node(1, south, minutesAgo: 5), node(1, national, minutesAgo: 60),   // heard on both
                   node(2, national, minutesAgo: 10),                                    // only on the other
                   node(3, "", minutesAgo: 300),                                         // before networks were kept
                   node(4, south, minutesAgo: 1)]
        let v = HeardByNetwork(all, network: south)
        #expect(Set(v.here.map(\.key)) == [key(1), key(3), key(4)])
        #expect(v.here.first { $0.key == key(1) }?.network == south)   // this network's record
        #expect(v.onlyElsewhere == [key(2)])
        #expect(v.others.map(\.network) == [national])
        #expect(v.others.first?.nodes.count == 2)
        #expect(v.anywhere.count == 4)
        // the network not known yet (never connected): everything counts as here
        #expect(HeardByNetwork(all, network: nil).here.count == 4)
        #expect(HeardByNetwork(all, network: nil).onlyElsewhere.isEmpty)
    }

    @Test func heardPerNetworkInTheStore() throws {
        let store = try Store.inMemory()
        try store.save(node(1, south, minutesAgo: 5, hops: 1))
        try store.save(node(1, national, minutesAgo: 60, hops: 0))
        try store.save(node(2, "", minutesAgo: 30))
        #expect(try store.heard(network: south).map(\.key).sorted() == [key(1), key(2)])
        #expect(try store.heard(network: national).map(\.key).sorted() == [key(1), key(2)])
        #expect(try store.heard(network: south).first { $0.key == key(1) }?.hops == 1)
        #expect(try store.heard(network: national).first { $0.key == key(1) }?.hops == 0)
        #expect(try store.heardEverywhere().count == 3)
        #expect(try store.heardNode(key(1))?.network == south)   // the one heard last
        #expect(try store.heardNode(key(1), network: national)?.hops == 0)
    }

    @Test func packetsAndRoutesPerNetwork() throws {
        let store = try Store.inMemory()
        for net in [south, national, nil] {
            try store.insert(PacketRecord(date: now, route: "flood", type: "ADVERT", hops: 0, path: "", hashSize: 1, snr: 5, rssi: -90,
                                          fingerprint: 1, raw: Data([1]), channelHash: nil, network: net))
            try store.insert(Message(date: now, senderTimestamp: 1, conversation: .channel(0), direction: .incoming, sender: "A",
                                     text: "hej", status: .received, path: "39", network: net))
        }
        #expect(try store.recentPackets(since: now - 60, network: south).map(\.network) == [nil, south])   // and from before
        #expect(try store.packets(network: national).count == 2)
        #expect(try store.packets().count == 3)
        #expect(try store.channelRoutes(since: now - 60, network: south).count == 2)
    }

    @Test func theOldRecordsMoveOver() throws {
        // a record per node, on whichever network it was heard last (or none)
        let row = "INSERT INTO heard (key, name, type, firstHeard, lastHeard, snr, rssi, hops, path, hashSize, count, network) VALUES "
        let store = try Store.upgraded(from: "telemetry", after: [
            row + "('aa', 'Szczyt', 2, '2026-11-01 10:00:00.000', '2026-11-10 10:00:00.000', 5, -90, 1, '39', 1, 7, '\(south)')",
            row + "('bb', 'Old', 1, '2026-01-01 10:00:00.000', '2026-01-02 10:00:00.000', 2, -100, 2, '', 1, 1, NULL)",
        ])
        #expect(try store.heardNode("aa", network: south)?.count == 7)
        #expect(try store.heardNode("bb", network: "")?.name == "Old")
        #expect(try store.heard(network: national).map(\.key) == ["bb"])   // not known: counts everywhere
    }

    @Test func whereAConversationChangedNetwork() {
        let nets: [String?] = [nil, south, south, nil, national, national, south]
        let messages = nets.map { Message(senderTimestamp: 1, conversation: .channel(0), direction: .incoming, sender: "A",
                                          text: "x", status: .received, network: $0) }
        #expect(messages.indices.map { Message.networkChange(messages, at: $0) } == [nil, nil, nil, nil, national, nil, south])
    }
}

// The demo (trying MeshChat without a radio): its simulated radio and made-up mesh hang together.
@Suite("Demo")
struct DemoTests {
    @Test func theDemoMeshConnectsAndHasHistory() async throws {
        let store = try Store.inMemory()
        DemoMesh.seed(store)
        let engine = MeshEngine(store: store)
        await engine.connect(DemoMesh.makeRadio())
        #expect(await engine.state == .connected("Demo radio"))
        #expect(await engine.me?.name == "Bursztyn")
        #expect(await engine.network == DemoMesh.network)
        #expect(await engine.contacts.count == DemoMesh.nodes.count)
        #expect(await engine.channels.map(\.name) == ["Public", "#trojmiasto"])
        // what the screens show: heard nodes on the demo network, repeaters worked out from the packet log
        #expect(try store.heard(network: DemoMesh.network).count == DemoMesh.nodes.count)
        let dir = NodeDirectory(contacts: Array(await engine.contacts.values), heard: try store.heard(network: DemoMesh.network), home: DemoMesh.home)
        let a = RepeaterAnalysis(packets: try store.recentPackets(since: .now - 7 * 86400, network: DemoMesh.network),
                                 channelRoutes: try store.channelRoutes(since: .now - 7 * 86400, network: DemoMesh.network), directory: dir)
        #expect(Set(a.list.map(\.name)).isSuperset(of: ["Pachołek RPT", "Donas RPT", "Biskupia Górka RPT", "Hel RPT"]))
        #expect(a.yours?.key == DemoMesh.pacholek.key.hex)   // the demo's own message entered the mesh there
        // nothing is in the future (it would read "in 5 minutes")
        #expect(try store.recentPackets(since: .distantPast).allSatisfy { $0.date.timeIntervalSinceNow <= 1 })
        #expect(try store.messages(in: .channel(0)).count == 9)
    }
}

// Blocking someone: what's hidden, and what isn't.
@Suite("Blocking")
struct BlockingTests {
    let troll = PublicKey(Data(repeating: 0x7E, count: 32))!
    let friend = PublicKey(Data(repeating: 0x5A, count: 32))!

    func msg(_ c: ConversationID, from sender: String?, _ d: Direction = .incoming) -> Message {
        Message(senderTimestamp: 1, conversation: c, direction: d, sender: sender, text: "x", status: .received)
    }

    @Test func hidesTheirMessagesEverywhere() {
        var b = BlockList()
        b.block(name: "Troll", key: troll.hex)
        b.block(name: "Troll", key: troll.hex)   // once
        #expect(b.entries.count == 1)
        #expect(b.hides(msg(.channel(0), from: "Troll")))            // on a channel, by name
        #expect(b.hides(msg(.direct(troll), from: "Troll 2")))       // in a DM, by key, whatever the name
        #expect(b.hides(.direct(troll)) && !b.hides(.direct(friend)))
        #expect(!b.hides(msg(.channel(0), from: "Mewa")))
        #expect(!b.hides(msg(.channel(0), from: nil, .outgoing)))    // yours never
        b.unblock(b.entries[0])
        #expect(!b.hides(msg(.channel(0), from: "Troll")))
    }
}
