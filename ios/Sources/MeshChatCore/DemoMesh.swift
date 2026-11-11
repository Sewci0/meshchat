import CryptoKit
import Foundation
import MeshCoreKit

/// A made-up mesh for trying MeshChat without a radio (and for App Store review and screenshots): a
/// simulated radio, "Bursztyn", on MeshCore Polska's settings around Gdańsk, Gdynia and Sopot, with
/// repeaters on public hills, people with nicknames, channels and a few days of history. Nothing in it is
/// real: the names, keys and messages are invented, and positions are public landmarks.
public enum DemoMesh {
    public struct Node: Sendable {
        public let name: String
        public let type: NodeType
        public let key: PublicKey
        public let position: Position
        /// the repeaters its packets come through, first to last (key prefixes, one byte each)
        public let path: [UInt8]
        public let snr: Double
    }

    /// the network the demo radio is on (MeshCore Polska's settings)
    public static let radio = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
    public static var network: String { NetworkKey(radio).key }

    /// where distances are measured from in the demo: Gdańsk's main town
    public static let home = Position(latitude: 54.3520, longitude: 18.6466)
    /// the map's first view in the demo: the mesh from Gdańsk and Gdynia to Hel
    public static let overview = Position(latitude: 54.46, longitude: 18.60)
    public static let overviewZoom = 9.0
    public static let myName = "Bursztyn"
    public static let myKey = key(0xB7, "Bursztyn")

    // repeaters: the first byte of each key is what paths carry
    static let wiezyca = node("Wieżyca RPT", .repeater, 0x1A, 54.2268, 18.1199, path: [0x1A, 0x2B, 0x3C], snr: -4.5)
    static let donas = node("Donas RPT", .repeater, 0x2B, 54.4766, 18.4813, path: [], snr: 2.25)
    static let pacholek = node("Pachołek RPT", .repeater, 0x3C, 54.4134, 18.5609, path: [], snr: 7.5)
    static let biskupia = node("Biskupia Górka RPT", .repeater, 0x4D, 54.3420, 18.6420, path: [], snr: 4.0)
    static let lysa = node("Łysa Góra RPT", .repeater, 0x5E, 54.4278, 18.5525, path: [0x5E, 0x3C], snr: 1.5)
    static let hel = node("Hel RPT", .repeater, 0x6F, 54.6082, 18.8016, path: [0x6F, 0x2B], snr: -7.0)
    static let room = node("Trójmiasto Room", .room, 0xC3, 54.3713, 18.6123, path: [0x4D], snr: 3.5)

    // people (nicknames only), at public places
    static let mewa = node("Mewa", .companion, 0x81, 54.4466, 18.5703, path: [0x5E, 0x3C], snr: 5.25)
    static let latarnik = node("Latarnik", .companion, 0x92, 54.4810, 18.5650, path: [0x2B, 0x3C], snr: 6.5)
    static let kaszub = node("Kaszub", .companion, 0xA4, 54.3340, 18.1960, path: [0x1A, 0x2B, 0x3C], snr: 3.0)
    static let foka = node("Foka", .companion, 0xD5, 54.6960, 18.6790, path: [0x6F, 0x2B], snr: -2.5)
    static let neptun = node("Neptun", .companion, 0xE6, 54.3486, 18.6533, path: [0x4D], snr: 8.0)
    static let zuraw = node("Żuraw", .companion, 0xF7, 54.3502, 18.6578, path: [0x4D, 0x3C], snr: 4.75)

    public static let repeaters = [wiezyca, donas, pacholek, biskupia, lysa, hel]
    public static let people = [mewa, latarnik, kaszub, foka, neptun, zuraw]
    public static var nodes: [Node] { repeaters + [room] + people }

    public static let publicChannel = ChannelInfo(index: 0, name: "Public", secret: Data([0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a,
                                                                                    0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72]))
    public static let localChannel = ChannelInfo(index: 1, name: "#trojmiasto", secret: ChannelCrypto.hashtagKey("#trojmiasto"))

    /// The demo radio: its contacts, channels and settings, answering as MeshCore's firmware does. The
    /// repeaters heard directly answer a reach check.
    public static func makeRadio(now: Date = .now) -> SimulatedRadio {
        let t = UInt32(now.timeIntervalSince1970)
        let contacts = nodes.enumerated().map { i, n in
            Contact(key: n.key, type: n.type, flags: n.name == "Mewa" ? 1 : 0,
                    outPath: n.type == .companion && n.path.count <= 2 ? OutPath(hashSize: 1, hops: n.path.map { Data([$0]) }) : nil,
                    name: n.name, lastAdvert: t - UInt32(300 + i * 420), position: n.position, lastModified: t - UInt32(240 + i * 420))
        }
        let radio = SimulatedRadio(contacts: contacts, channels: [publicChannel, localChannel])
        radio.label = "Demo radio"
        radio.myName = myName
        radio.myKey = myKey
        radio.use(Self.radio)
        radio.reachAnswers = [(pacholek.key.prefix(8), 7.25, 6.5), (biskupia.key.prefix(8), 4.0, 3.25), (donas.key.prefix(8), -2.5, 1.0)]
        radio.neighbours = [(pacholek.key.prefix(4), 120, 26), (donas.key.prefix(4), 900, 6), (lysa.key.prefix(4), 1800, 14)]
        return radio
    }

    /// Fills `store` with the demo's history: who was heard where, three days of packets through the
    /// repeaters, and conversations on the channels and with Mewa.
    public static func seed(_ store: Store, now: Date = .now) {
        let net = network
        let builder = SimulatedRadio(contacts: [], channels: [])
        // heard nodes: each from its own path
        for (i, n) in nodes.enumerated() {
            let last = now.addingTimeInterval(-Double(180 + i * 400))
            try? store.save(HeardNode(key: n.key.hex, name: n.name, type: Int(n.type.rawValue), latitude: n.position.latitude,
                                      longitude: n.position.longitude, firstHeard: now.addingTimeInterval(-9 * 86400), lastHeard: last,
                                      snr: n.snr, rssi: Int(-100 + n.snr * 2), hops: n.path.count,
                                      path: n.path.map { String(format: "%02x", $0) }.joined(), hashSize: 1, count: 20 + i * 3, network: net))
        }
        // the packet log: adverts every few hours and channel traffic through the repeaters, oldest first
        var packets: [(Date, Data, Double)] = []
        for hour in stride(from: 72, through: 0, by: -1) {
            let at = now.addingTimeInterval(-Double(hour) * 3600)
            for (i, n) in nodes.enumerated() where (hour + i) % 3 == 0 {
                packets.append((at.addingTimeInterval(-Double(300 + i * 97)), builder.advertPacket(key: n.key, type: n.type, name: n.name, path: n.path), n.snr))
            }
            for (i, p) in people.enumerated() where (hour + i) % 2 == 0 {
                let text = "\(p.name): " + chatter[(hour + i) % chatter.count]
                packets.append((at.addingTimeInterval(-Double(1200 + i * 131)),
                                builder.groupTextPacket(key: publicChannel.secret, timestamp: UInt32(at.timeIntervalSince1970), text: text, path: p.path), p.snr))
            }
        }
        // the repeaters heard straight from them lately
        for (i, r) in [pacholek, biskupia, donas].enumerated() {
            packets.append((now.addingTimeInterval(-Double(60 + i * 240)), builder.advertPacket(key: r.key, type: .repeater, name: r.name), r.snr))
        }
        @discardableResult func log(_ raw: Data, at: Date, snr: Double) -> MeshPacket? {
            guard let p = MeshPacket(raw: raw) else { return nil }
            _ = try? store.insert(PacketRecord(date: at, route: "\(p.route)", type: p.payloadType.name, hops: p.hops, path: p.path.map(\.hex).joined(),
                                               hashSize: p.hashSize, snr: snr, rssi: Int(-100 + snr * 2), fingerprint: Int64(p.fingerprint), raw: raw,
                                               channelHash: p.payloadType == .groupText ? p.payload.first.map(Int.init) : nil, network: net))
            return p
        }
        for (at, raw, snr) in packets.sorted(by: { $0.0.timeIntervalSince1970 < $1.0.timeIntervalSince1970 }) { log(raw, at: at, snr: snr) }
        // conversations, oldest first. Each channel message heard has its packet in the log, so its details
        // show how it travelled; Kaszub's came twice, over two routes.
        let secrets = [publicChannel.index: publicChannel.secret, localChannel.index: localChannel.secret]
        for var m in conversation(now: now) {
            if m.direction == .incoming, case .channel(let i) = m.conversation, let secret = secrets[i], let sender = m.sender,
               let node = nodes.first(where: { $0.name == sender }), let ts = m.senderTimestamp {
                var routes = [(node.path, node.snr, 0.0)]
                if sender == kaszub.name { routes.append(([0x1A, 0x5E, 0x3C], node.snr - 2.75, 2.1)) }
                for (path, snr, delay) in routes {
                    let raw = builder.groupTextPacket(key: secret, timestamp: ts, text: "\(sender): \(m.text)", path: path)
                    if let p = log(raw, at: m.date.addingTimeInterval(delay), snr: snr) { m.fingerprint = Int64(p.fingerprint) }
                }
            }
            _ = try? store.insert(m)
        }
    }

    /// what the made-up people say on Public, over three days (for the packet log)
    static var chatter: [String] {
        [String(localized: "Good morning from the mesh!", comment: "Demo chat message"),
         String(localized: "Anyone on the channel?", comment: "Demo chat message"),
         String(localized: "Heard you via Donas, 2 hops", comment: "Demo chat message"),
         String(localized: "Testing a new antenna", comment: "Demo chat message")]
    }

    static func conversation(now: Date) -> [Message] {
        let net = network
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func path(_ n: Node) -> String { n.path.map { String(format: "%02x", $0) }.joined() }
        func incoming(_ c: ConversationID, _ n: Node, _ text: String, _ minutes: Double) -> Message {
            Message(date: ago(minutes), senderTimestamp: UInt32(ago(minutes).timeIntervalSince1970), conversation: c, direction: .incoming,
                    sender: n.name, text: text, status: .received, hops: n.path.count, path: path(n), hashSize: 1, snr: n.snr,
                    rssi: Int(-100 + n.snr * 2), network: net)
        }
        func mine(_ c: ConversationID, _ text: String, _ minutes: Double, _ status: MessageStatus, path: String? = nil, repeats: Int = 0) -> Message {
            var m = Message(date: ago(minutes), senderTimestamp: UInt32(ago(minutes).timeIntervalSince1970), conversation: c, direction: .outgoing,
                            sender: nil, text: text, status: status, hops: path.map { $0.count / 2 }, path: path, hashSize: 1, network: net)
            m.repeats = repeats
            return m
        }
        let pub = ConversationID.channel(0), local = ConversationID.channel(1), dm = ConversationID.direct(mewa.key)
        return [
            incoming(local, kaszub, String(localized: "Wieżyca RPT is back after the storm", comment: "Demo chat message"), 190),
            incoming(local, foka, String(localized: "Thanks! I hear Hel RPT again", comment: "Demo chat message"), 175),
            incoming(pub, kaszub, String(localized: "Range test from Wieżyca at noon, who's in?", comment: "Demo chat message"), 150),
            incoming(pub, neptun, String(localized: "Count me in, I'll take the handheld up the hill", comment: "Demo chat message"), 146),
            incoming(pub, latarnik, String(localized: "Good morning from Orłowo! Anyone hear me?", comment: "Demo chat message"), 64),
            incoming(pub, mewa, String(localized: "Loud and clear via Pachołek 👍", comment: "Demo chat message"), 61),
            incoming(pub, zuraw, String(localized: "Anyone from Hel on the channel today?", comment: "Demo chat message"), 40),
            incoming(pub, foka, String(localized: "Here! Greetings from the beach 🌊", comment: "Demo chat message"), 37),
            mine(pub, String(localized: "Test from Oliwa, who hears me?", comment: "Demo chat message"), 22, .repeated, path: "3c", repeats: 3),
            incoming(pub, kaszub, String(localized: "Heard you via Donas, 3 hops, SNR +6", comment: "Demo chat message"), 20),
            incoming(pub, neptun, String(localized: "Straight through Biskupia Górka here", comment: "Demo chat message"), 18),
            incoming(local, neptun, String(localized: "Coffee at Długi Targ on Saturday?", comment: "Demo chat message"), 12),
            incoming(dm, mewa, String(localized: "Are you coming to the meetup on Saturday?", comment: "Demo chat message"), 95),
            mine(dm, String(localized: "Yes! I'll bring the new repeater", comment: "Demo chat message"), 90, .delivered),
            incoming(dm, mewa, String(localized: "Great, see you at 10 🙂", comment: "Demo chat message"), 88),
        ]
    }

    static func node(_ name: String, _ type: NodeType, _ first: UInt8, _ lat: Double, _ lon: Double, path: [UInt8], snr: Double) -> Node {
        Node(name: name, type: type, key: key(first, name), position: Position(latitude: lat, longitude: lon), path: path, snr: snr)
    }

    /// a made-up key: `first`, then bytes of the name's hash
    static func key(_ first: UInt8, _ name: String) -> PublicKey {
        PublicKey(Data([first]) + Data(SHA256.hash(data: Data(("meshchat demo " + name).utf8))).prefix(31))!
    }
}
