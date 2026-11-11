import CommonCrypto
import CryptoKit
import Foundation

/// A radio in memory that answers commands as MeshCore's firmware does (examples/companion_radio): the
/// tests' radio, and the demo's (trying the app without hardware, and its screenshots).
public final class SimulatedRadio: MeshTransport, @unchecked Sendable {
    public let frames: AsyncThrowingStream<Data, Error>
    private let sink: AsyncThrowingStream<Data, Error>.Continuation
    /// for the UI: "fake radio" in the tests
    public var label = "fake radio"

    private let lock = NSLock()
    public var myKey = PublicKey(Data(repeating: 0xA1, count: 32))!
    public var myName = "MrE"
    /// its own position, as its adverts carry it (nil: none)
    public var myPosition: Position?
    public private(set) var contacts: [Contact]
    public var channels: [ChannelInfo]
    /// messages waiting in the queue (reply frames)
    public var queue: [Data] = []
    /// which DM try (0-based) gets an ACK; nil: none
    public var ackOnAttempt: Int?
    /// a repeater passes on our channel messages
    public var echoChannelSends = false
    public private(set) var commands: [Data] = []
    private var tag: UInt32 = 0x1000
    /// remote nodes: logins are refused (the answer a wrong password gets from some firmware)
    public var refuseLogins = false
    /// the role a login gets (0 guest, 1 read-only, 2 read-write, 3 admin)
    public var loginRole: UInt8 = 2
    /// what a repeater says it hears directly: key prefix, seconds ago, SNR × 4
    public var neighbours: [(prefix: Data, secondsAgo: Int32, snr4: Int8)] = []
    /// repeaters that answer a reach check: 8 bytes of their key, how well each side heard the other
    public var reachAnswers: [(prefix: Data, snrThere: Double, snrHere: Double)] = []
    /// what remote nodes answer a telemetry request with (Cayenne LPP): 4.12 V battery, 21.5 °C
    public var telemetry = Data([1, 116, 0x01, 0x9C, 1, 103, 0x00, 0xD7])
    /// remote nodes don't share telemetry (as a person who allows nobody): no answer
    public var shareNoTelemetry = false
    /// remote nodes: requests sent along a saved route get no answer (floods still do)
    public var routeIsDead = false
    /// its LoRa settings in kHz (frequency ×1000, bandwidth ×1000), spreading factor and coding rate:
    /// MeshCore Południe until set otherwise
    public private(set) var radio: (freq: UInt32, bw: UInt32, sf: UInt8, cr: UInt8) = (869_618, 62_500, 6, 8)
    public private(set) var pin: UInt32 = 123456
    public private(set) var rebooted = false
    /// admin commands received (CLI_DATA messages), as sent
    public private(set) var adminCommands: [String] = []

    public init(contacts: [Contact], channels: [ChannelInfo]) {
        self.contacts = contacts
        self.channels = channels
        (frames, sink) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public func connect() async throws {}
    public func disconnect() { sink.finish() }

    public func push(_ frame: Data) { sink.yield(frame) }

    /// Puts it on these LoRa settings, as setting them over the protocol would.
    public func use(_ r: RadioSettings) {
        lock.withLock { radio = (UInt32((r.frequencyMHz * 1000).rounded()), UInt32((r.bandwidthKHz * 1000).rounded()),
                                 UInt8(r.spreadingFactor), UInt8(r.codingRate)) }
    }

    public func pushLater(_ frame: Data, ms: Int = 20) {
        Task { try? await Task.sleep(for: .milliseconds(ms)); self.push(frame) }
    }

    /// Adds a contact before the engine connects (for one test's own nodes).
    public func add(_ c: Contact) { lock.withLock { contacts.append(c) } }

    public func contact(_ key: PublicKey) -> Contact? { lock.withLock { contacts.first { $0.key == key } } }

    public func send(_ frame: Data) async throws {
        lock.withLock { commands.append(frame) }
        var r = ByteReader(frame)
        let code = try r.u8()
        switch code {
        case 22:   // device query
            var w = ByteWriter(13); w.u8(14); w.u8(175); w.u8(8); w.u32(123456)
            w.string("15 Oct 2026", size: 12); w.string("Fake Board", size: 40); w.string("v1.18.0", size: 20); w.u8(0); w.u8(0)
            push(w.data)
        case 1:    // app start
            var w = ByteWriter(5); w.u8(1); w.i8(22); w.u8(22); w.bytes(myKey.bytes)
            w.i32(myPosition.map { Int32(($0.latitude * 1e6).rounded()) } ?? 0); w.i32(myPosition.map { Int32(($0.longitude * 1e6).rounded()) } ?? 0)
            let s = lock.withLock { radio }
            w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u32(s.freq); w.u32(s.bw); w.u8(s.sf); w.u8(s.cr); w.text(myName, maxBytes: 31)
            push(w.data)
        case 11:   // radio settings
            let s = (try r.u32(), try r.u32(), try r.u8(), try r.u8())
            lock.withLock { radio = s }
            push(Data([0]))
        case 5:    // time: well in the past, so the engine sets it
            var w = ByteWriter(9); w.u32(1_000); push(w.data)
        case 4:    // contacts
            let list = lock.withLock { contacts }
            var s = ByteWriter(2); s.u32(UInt32(list.count)); push(s.data)
            for c in list { push(contactFrame(c)) }
            var e = ByteWriter(4); e.u32(42); push(e.data)
        case 30:   // contact by key
            let k = PublicKey(try r.bytes(32))!
            if let c = contact(k) { push(contactFrame(c)) } else { push(Data([1, 2])) }
        case 31:   // channel slot
            let i = Int(try r.u8())
            if let c = channels.first(where: { $0.index == i }) {
                var w = ByteWriter(18); w.u8(UInt8(i)); w.string(c.name, size: 32); w.bytes(c.secret); push(w.data)
            } else if i < 8 {
                var w = ByteWriter(18); w.u8(UInt8(i)); w.string("", size: 32); w.bytes(Data(count: 16)); push(w.data)
            } else { push(Data([1, 2])) }
        case 10:   // next message
            let next: Data? = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
            push(next ?? Data([10]))
        case 3:    // channel message
            _ = try r.u8(); let slot = Int(try r.u8()); let ts = try r.u32(); let text = r.restString()
            push(Data([0]))
            if echoChannelSends, let ch = channels.first(where: { $0.index == slot }) {
                pushLater(rxLog(groupTextPacket(key: ch.secret, timestamp: ts, text: "\(myName): \(text)", path: [0x39]), snr: 7))
            }
        case 2:    // DM, or an admin command
            let type = try r.u8(); let attempt = Int(try r.u8()); _ = try r.u32(); let prefix = try r.bytes(6)
            if type == 1 {   // CLI_DATA: "sent" with no ACK; the node answers with a CLI_DATA message
                let command = r.restString()
                lock.withLock { adminCommands.append(command) }
                var w = ByteWriter(6); w.u8(0); w.u32(0); w.u32(800); push(w.data)
                if let node = lock.withLock({ contacts.first { $0.key.bytes.starts(with: prefix) } }) {
                    let answer = cliAnswerFrame(from: node.key, text: Self.answer(to: command))
                    lock.withLock { queue.append(answer) }
                    pushLater(Data([0x83]))
                }
                break
            }
            let flood = lock.withLock { contacts.first { $0.key.bytes.starts(with: prefix) }?.outPath == nil }
            tag += 1
            var w = ByteWriter(6); w.u8(flood ? 1 : 0); w.u32(tag); w.u32(0); push(w.data)
            if attempt == ackOnAttempt { var a = ByteWriter(0x82); a.u32(tag); a.u32(1834); pushLater(a.data) }
        case 32:   // set channel: an empty name frees the slot
            let i = Int(try r.u8()), name = try r.string(32), secret = try r.bytes(16)
            lock.withLock {
                channels.removeAll { $0.index == i }
                if !name.isEmpty { channels.append(ChannelInfo(index: i, name: name, secret: secret)); channels.sort { $0.index < $1.index } }
            }
            push(Data([0]))
        case 9:    // add or update a contact (the whole record)
            let key = PublicKey(try r.bytes(32))!, type = NodeType(raw: try r.u8())
            let flags = try r.u8(), pathLength = try r.u8(), path = try r.bytes(64)
            let name = try r.string(32)
            let advert = r.remaining >= 4 ? try r.u32() : 0
            if r.remaining >= 8 { _ = try r.bytes(8) }   // position
            // the firmware takes the time given, else now
            let modified = r.remaining >= 4 ? try r.u32() : UInt32(Date().timeIntervalSince1970)
            lock.withLock {
                let route = contacts.first { $0.key == key }.flatMap { _ in OutPath.decode(lengthByte: pathLength, path: path) }
                contacts.removeAll { $0.key == key }
                contacts.append(Contact(key: key, type: type, flags: flags, outPath: route, name: name, lastAdvert: advert, lastModified: modified))
            }
            push(Data([0]))
        case 15:   // remove a contact
            let key = PublicKey(try r.bytes(32))!
            let had = lock.withLock { () -> Bool in
                let n = contacts.count
                contacts.removeAll { $0.key == key }
                return contacts.count < n
            }
            push(had ? Data([0]) : Data([1, 2]))
        case 37:   // Bluetooth PIN: 0, or six digits
            let p = try r.u32()
            if p == 0 || (100_000...999_999).contains(p) { lock.withLock { pin = p }; push(Data([0])) } else { push(Data([1, 6])) }
        case 19:   // reboot: no answer, the link drops
            lock.withLock { rebooted = true }
            sink.finish()
        case 26:   // login to a remote node
            let key = PublicKey(try r.bytes(32))!
            let t = sent()
            if silent(key) { break }
            if refuseLogins {
                pushLater(Data([0x86, 0]) + key.prefix(6))
            } else {
                var w = ByteWriter(0x85); w.u8(loginRole == 3 ? 1 : 0); w.bytes(key.prefix(6)); w.u32(1_794_000_000); w.u8(loginRole); w.u8(1)
                pushLater(w.data)
            }
            _ = t
        case 39:   // telemetry of a remote node: [39][3 spare][key]
            _ = try r.bytes(3)
            let key = PublicKey(try r.bytes(32))!
            _ = sent()
            if silent(key) || lock.withLock({ shareNoTelemetry }) { break }
            pushLater(Data([0x8B, 0]) + key.prefix(6) + telemetry)
        case 55:   // control data: a reach check ("which repeaters hear me?"); each listed repeater answers
            let flags = try r.u8()
            _ = try r.u8()
            let t = try r.u32()
            push(Data([0]))
            guard flags & 0xF0 == ControlData.discoverRequest else { break }
            for a in lock.withLock({ reachAnswers }) {
                var w = ByteWriter(0x8E)
                w.i8(Int8(a.snrHere * 4)); w.i8(-90); w.u8(0)
                w.u8(ControlData.discoverResponse | 2); w.i8(Int8(a.snrThere * 4)); w.u32(t); w.bytes(a.prefix)
                pushLater(w.data, ms: 40)
            }
        case 27:   // status of a remote node
            let key = PublicKey(try r.bytes(32))!
            _ = sent()
            if silent(key) { break }
            pushLater(Data([0x87, 0]) + key.prefix(6) + Self.status)
        case 50:   // binary request: neighbours
            let key = PublicKey(try r.bytes(32))!
            let t = sent()
            if silent(key) { break }
            var w = ByteWriter(0x8C); w.u8(0); w.u32(t)
            let list = lock.withLock { neighbours }
            w.u16(UInt16(list.count)); w.u16(UInt16(list.count))
            for n in list { w.bytes(n.prefix); w.i32(n.secondsAgo); w.i8(n.snr4) }
            pushLater(w.data)
        case 13:   // reset path
            let k = PublicKey(try r.bytes(32))!
            lock.withLock { if let i = contacts.firstIndex(where: { $0.key == k }) { contacts[i].outPath = nil } }
            push(Data([0]))
        default:
            push(Data([0]))
        }
    }

    // MARK: frames the radio sends

    /// A request on a dead route: it goes out, nothing comes back.
    private func silent(_ key: PublicKey) -> Bool { routeIsDead && contact(key)?.outPath != nil }

    /// "Sent" with a new tag and a short timeout estimate.
    private func sent() -> UInt32 {
        let t = lock.withLock { () -> UInt32 in tag += 1; return tag }
        var w = ByteWriter(6); w.u8(1); w.u32(t); w.u32(1000); push(w.data)
        return t
    }

    /// A node's stats: 4.12 V, noise −117 dBm, last packet −98 dBm at 7.25 dB, up 2 days; a room's
    /// 12 posts and 30 pushes.
    public static let status: Data = {
        var w = ByteWriter(0)
        w.u16(4120); w.u16(0); w.u16(UInt16(bitPattern: -117)); w.u16(UInt16(bitPattern: -98))
        w.u32(5000); w.u32(1200); w.u32(3600); w.u32(172_800)
        w.u32(700); w.u32(500); w.u32(4000); w.u32(1000)
        w.u16(0); w.u16(29); w.u16(3); w.u16(40)
        w.u16(12); w.u16(30)
        return Data(w.data.dropFirst())
    }()

    public func contactFrame(_ c: Contact) -> Data {
        var f = Codec.addUpdateContact(c, lastModified: c.lastModified)
        f[0] = 3
        return f
    }

    /// A flooded ADVERT packet: header 0x11, path, then key, time, a (blank) signature, flags and name.
    public func advertPacket(key: PublicKey, type: NodeType, name: String, path: [UInt8] = []) -> Data {
        var p = Data([0x11, UInt8(path.count)]) + Data(path)
        p.append(key.bytes)
        p.append(contentsOf: withUnsafeBytes(of: UInt32(1_794_000_000).littleEndian, Array.init))
        p.append(Data(count: 64))
        p.append(0x80 | type.rawValue)
        p.append(Data(name.utf8))
        return p
    }

    public func rxLog(_ raw: Data, snr: Double = 6, rssi: Int = -100) -> Data {
        Data([0x88, UInt8(bitPattern: Int8(snr * 4)), UInt8(bitPattern: Int8(rssi))]) + raw
    }

    /// A flooded GRP_TXT packet: header 0x15, path, then channel hash, MAC and AES-128-ECB ciphertext.
    public func groupTextPacket(key: Data, timestamp: UInt32, text: String, path: [UInt8]) -> Data {
        var plain = ByteWriter(0); plain.u32(timestamp); plain.u8(0); plain.text(text, maxBytes: 160)
        var p = plain.data.dropFirst()   // drop ByteWriter's code byte
        p.append(Data(count: (16 - p.count % 16) % 16))
        let cipher = aesECB(Data(p), key: key)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: cipher, using: SymmetricKey(data: key + Data(count: 16)))).prefix(2)
        return Data([0x15, UInt8(path.count)] + path) + Data([ChannelCrypto.hash(of: key)]) + mac + cipher
    }

    /// What a repeater answers to a few admin commands, as MeshCore's firmware words them.
    static func answer(to command: String) -> String {
        switch command {
        case "ver": return "v1.11.0-fake (Build: 15-Oct-2026)"
        case "get name": return "> Fake RPT"
        case "get radio": return "> 869.618,62.5,6,8"
        case "clock sync": return "OK - clock set: 12:00 - 10/11/2026 UTC"
        default:
            if command.hasPrefix("password ") { return "password now: " + command.dropFirst(9) }
            if command.hasPrefix("set ") { return "OK" }
            return "Unknown command"
        }
    }

    // the text type goes out as the number itself (MyMesh::queueMessage): 0 plain, 1 a command's
    // answer, 2 a signed room post
    public func cliAnswerFrame(from: PublicKey, text: String) -> Data {
        var w = ByteWriter(16); w.i8(24); w.u16(0); w.bytes(from.prefix(6)); w.u8(0xFF); w.u8(1); w.u32(1_794_000_500)
        w.text(text, maxBytes: 160)
        return w.data
    }

    public func channelMessageFrame(slot: Int, timestamp: UInt32, text: String, hops: Int) -> Data {
        var w = ByteWriter(17); w.i8(24); w.u16(0); w.u8(UInt8(slot)); w.u8(UInt8(hops)); w.u8(0); w.u32(timestamp); w.text(text, maxBytes: 160)
        return w.data
    }

    public func directMessageFrame(from: PublicKey, timestamp: UInt32, text: String, author: Data? = nil) -> Data {
        var w = ByteWriter(16); w.i8(20); w.u16(0); w.bytes(from.prefix(6)); w.u8(0xFF); w.u8(author == nil ? 0 : 2); w.u32(timestamp)
        if let author { w.bytes(author) }
        w.text(text, maxBytes: 160)
        return w.data
    }

    private func aesECB(_ data: Data, key: Data) -> Data {
        var out = Data(count: data.count)
        var moved = 0
        _ = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                }
            }
        }
        return out
    }
}
