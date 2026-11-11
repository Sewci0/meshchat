import Foundation
import Testing
@testable import MeshCoreKit

// Vectors: channel IDs as the user's radio reported them; the encrypted packet made by MeshChat's Python
// channel decoder (firmware/tools/find_channel_names.py), itself checked against real packets.

@Suite("Channel crypto")
struct ChannelCryptoTests {
    @Test func hashtagKeysAndIDsMatchTheRadio() {
        #expect(ChannelCrypto.hashtagKey("#test").hex == "9cd8fcf22a47333b591d96a2b848b73f")
        #expect(ChannelCrypto.hash(of: ChannelCrypto.hashtagKey("#test")) == 0xD9)
        #expect(ChannelCrypto.hash(of: Data(hex: "8b3387e9c5cdea6ac9e5edbaa115cd72")!) == 0x11)   // Public
    }

    @Test func decryptsAGroupMessage() throws {
        let payload = try #require(Data(hex: "d9e85abb980cfd3736422e1ba7fbbc7cad1b95e20d5eda9bc0c5700f426b8524e9ecc35f567777dc63ea35784e639aed1ad7b4"))
        let plain = try #require(ChannelCrypto.decryptGroupText(payload, key: ChannelCrypto.hashtagKey("#test")))
        #expect(plain.timestamp == 1_794_262_000)
        #expect(plain.attempt == 1)
        #expect(plain.textType == .plain)
        #expect(plain.text == "MrE: zażółć gęślą jaźń 📡")
    }

    @Test func rejectsTheWrongKey() throws {
        let payload = try #require(Data(hex: "d9e85abb980cfd3736422e1ba7fbbc7cad1b95e20d5eda9bc0c5700f426b8524e9ecc35f567777dc63ea35784e639aed1ad7b4"))
        #expect(ChannelCrypto.decryptGroupText(payload, key: ChannelCrypto.hashtagKey("#tset")) == nil)
        var tampered = payload
        tampered[5] ^= 1
        #expect(ChannelCrypto.decryptGroupText(tampered, key: ChannelCrypto.hashtagKey("#test")) == nil)
    }
}

@Suite("Packets")
struct PacketTests {
    @Test func parsesAFloodedChannelPacket() throws {
        let raw = try #require(Data(hex: "1502394ed9e85abb980cfd3736422e1ba7fbbc7cad1b95e20d5eda9bc0c5700f426b8524e9ecc35f567777dc63ea35784e639aed1ad7b4"))
        let p = try #require(MeshPacket(raw: raw))
        #expect(p.route == .flood)
        #expect(p.payloadType == .groupText)
        #expect(p.version == 1)
        #expect(p.hops == 2)
        #expect(p.path.map(\.hex) == ["39", "4e"])
        #expect(p.fingerprint == 0xDDBB_4BCB)   // the same as the Python server's pkt_hash
    }

    @Test func parsesTwoByteHopsAndTransportCodes() throws {
        // transport flood (route 0), TXT_MSG (type 2): header 0x08, 4 transport bytes, path length 0x42 = 2 hops × 2 bytes
        let raw = try #require(Data(hex: "08aabbccdd423900" + "4e63" + "0102030405060708"))
        let p = try #require(MeshPacket(raw: raw))
        #expect(p.route == .transportFlood)
        #expect(p.transportCodes?.hex == "aabbccdd")
        #expect(p.hashSize == 2)
        #expect(p.path.map(\.hex) == ["3900", "4e63"])
        #expect(p.payload.hex == "0102030405060708")
    }

    @Test func shortPacketsDontCrash() {
        #expect(MeshPacket(raw: Data()) == nil)
        #expect(MeshPacket(raw: Data([0x15])) == nil)
        #expect(MeshPacket(raw: Data([0x15, 0x05, 0x01])) == nil)   // claims 5 hops, has 1 byte
    }
}

@Suite("Frames")
struct FrameTests {
    let key = PublicKey(Data((0..<32).map { UInt8($0) }))!

    @Test func contactRecordRoundTrips() throws {
        let c = Contact(key: key, type: .room, flags: 1, outPath: OutPath(hashSize: 2, hops: [Data([0x39, 0x00]), Data([0x4e, 0x63])]),
                        name: "LUNA🌑", lastAdvert: 1_794_000_000, position: Position(latitude: 50.5, longitude: 19.25), lastModified: 0)
        var frame = Codec.addUpdateContact(c)
        #expect(frame.count == 1 + 32 + 3 + 64 + 32 + 4 + 8)   // the whole record, position included
        frame[0] = 3   // the same layout the radio sends a contact in
        frame.append(contentsOf: [0, 0, 0, 0])   // last modified
        guard case .reply(.contact(let back))? = Codec.decode(frame) else { Issue.record("not a contact"); return }
        #expect(back.key == c.key)
        #expect(back.type == .room)
        #expect(back.outPath == c.outPath)
        #expect(back.name == "LUNA🌑")
        #expect(abs((back.position?.latitude ?? 0) - 50.5) < 1e-6)
    }

    @Test func noPositionAndGarbagePositionsAreNone() throws {
        var frame = Codec.addUpdateContact(Contact(key: key, type: .room, name: "x"))
        frame[0] = 3
        guard case .reply(.contact(let c))? = Codec.decode(frame) else { Issue.record("not a contact"); return }
        #expect(c.position == nil)
        #expect(Position(microdegreesLat: -2_113_897_072, lon: 1_070_513_424) == nil)   // what the radio's memory gave OST Ujazd
    }

    @Test func messagesFromTheQueue() throws {
        // channel message, v3: SNR 6.5 (26/4), channel 1, flooded over 3 one-byte hops, plain, timestamp, text
        var w = ByteWriter(17); w.i8(26); w.u16(0); w.u8(1); w.u8(3); w.u8(0); w.u32(1_794_000_000); w.text("Ala: hej", maxBytes: 150)
        guard case .reply(.message(.channel(let m)))? = Codec.decode(w.data) else { Issue.record("not a channel message"); return }
        #expect(m.snr == 6.5)
        #expect(m.channelIndex == 1)
        #expect(m.floodHops == 3)
        #expect(m.parts.sender == "Ala" && m.parts.body == "hej")

        // a room post: signed text, came direct (path byte 0xFF), with the author's 4-byte prefix
        var r = ByteWriter(16); r.i8(-8); r.u16(0); r.bytes(key.prefix(6)); r.u8(0xFF); r.u8(2); r.u32(1_715_775_784)
        r.bytes(Data([0x4a, 0x02, 0xfd, 0xba])); r.text("Test raz dwa trzy", maxBytes: 150)
        guard case .reply(.message(.contact(let post)))? = Codec.decode(r.data) else { Issue.record("not a contact message"); return }
        #expect(post.textType == .signedPlain)
        #expect(post.floodHops == nil)
        #expect(post.authorPrefix?.hex == "4a02fdba")
        #expect(post.text == "Test raz dwa trzy")
        #expect(post.snr == -2)

        // a repeater's answer to a command (text type 1, as the radio sends it: the number itself)
        var a = ByteWriter(16); a.i8(20); a.u16(0); a.bytes(key.prefix(6)); a.u8(0xFF); a.u8(1); a.u32(1_794_000_000)
        a.text("OK - clock set", maxBytes: 150)
        guard case .reply(.message(.contact(let answer)))? = Codec.decode(a.data) else { Issue.record("not a contact message"); return }
        #expect(answer.textType == .cliData)
        #expect(answer.authorPrefix == nil)
        #expect(answer.text == "OK - clock set")
    }

    @Test func sendCommandsAreByteExact() {
        let dm = Codec.sendText(to: key, text: "hi", timestamp: 0x0102_0304, attempt: 2)
        #expect(dm.hex == "020002" + "04030201" + "000102030405" + "6869")
        let ch = Codec.sendChannelText(channel: 4, text: "yo", timestamp: 1)
        #expect(ch.hex == "03" + "00" + "04" + "01000000" + "796f")
        #expect(Codec.setRadio(RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)).hex
                == "0b" + "f2440d00" + "24f40000" + "06" + "08")   // 869618 kHz, 62500 Hz
        #expect(Codec.setTxPower(-9).hex == "0cf7")
    }

    @Test func longTextIsCutOnACharacterBoundary() {
        let text = String(repeating: "ż", count: 100)   // 200 bytes
        let frame = Codec.sendChannelText(channel: 0, text: text, timestamp: 0)
        #expect(frame.count - 7 <= Codec.maxText)
        #expect(String(data: frame.suffix(from: 7), encoding: .utf8) != nil)
    }

    @Test func pushes() throws {
        var ack = ByteWriter(0x82); ack.u32(0xDEAD_BEEF); ack.u32(1834)
        guard case .push(.sendConfirmed(let a, let rtt))? = Codec.decode(ack.data) else { Issue.record("not an ACK"); return }
        #expect(a == 0xDEAD_BEEF && rtt == 1834)

        var login = ByteWriter(0x85); login.u8(0); login.bytes(key.prefix(6)); login.u32(1_794_251_831); login.u8(2); login.u8(1)
        guard case .push(.loginSuccess(let l))? = Codec.decode(login.data) else { Issue.record("not a login"); return }
        #expect(l.aclRole == 2 && l.firmwareLevel == 1 && l.serverTime == 1_794_251_831)

        guard case .push(.rxLog(let e))? = Codec.decode(Data([0x88, 27, 0x97]) + Data(hex: "1502394e")!) else { Issue.record("not RX"); return }
        #expect(e.snr == 6.75 && e.rssi == -105)
    }
}

@Suite("WiFi framing")
struct StreamFramingTests {
    @Test func reassemblesAcrossChunksAndSkipsNoise() {
        var f = StreamFraming()
        let a = Data([0x3E, 3, 0, 1, 2, 3]), b = Data([0x3E, 1, 0, 9])
        var got: [Data] = []
        got += f.feed(Data([0xAA, 0xBB]) + a.prefix(2))   // noise, then half a header
        got += f.feed(a.dropFirst(2) + b.prefix(3))
        got += f.feed(b.dropFirst(3))
        #expect(got == [Data([1, 2, 3]), Data([9])])
        #expect(StreamFraming.wrap(Data([7, 8])) == Data([0x3C, 2, 0, 7, 8]))
    }
}

@Suite("Text")
struct TextTests {
    @Test func utf8PrefixNeverSplitsACharacter() {
        #expect("zażółć".utf8Prefix(maxBytes: 3) == "za")
        #expect("📡📡".utf8Prefix(maxBytes: 5) == "📡")
        #expect(ByteReader.text(Data([0x68, 0x69, 0xC5])) == "hi\u{FFFD}")   // a name the radio cut mid-character
    }
}

@Suite("Reach")
struct ReachFrameTests {
    @Test func theRequestsAreByteExact() {
        // CMD_SEND_CONTROL_DATA: discover request (0x80) asking for key prefixes (bit 0), repeaters only, tag
        #expect(Codec.discoverRepeaters(tag: 0x0403_0201) == Data([55, 0x81, 0x04, 0x01, 0x02, 0x03, 0x04]))
        // CMD_SEND_TRACE_PATH: tag, auth 0, flags 2 (4-byte hashes), the path
        #expect(Codec.trace(tag: 1, flags: 2, path: Data([0xAA, 0xBB, 0xCC, 0xDD]))
                == Data([36, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test func aDiscoveryAnswer() throws {
        // PUSH_CODE_CONTROL_DATA: our SNR of it (6.0), RSSI −90, zero hops, then its answer: repeater,
        // its SNR of us (5.0), our tag, 8 bytes of its key
        let key = Data([0x39, 0x00, 1, 2, 3, 4, 5, 6])
        let frame = Data([0x8E, 24, UInt8(bitPattern: -90), 0, 0x92, 20, 0x01, 0x02, 0x03, 0x04]) + key
        guard case .push(.controlData(let c))? = Codec.decode(frame) else { Issue.record("not control data"); return }
        let a = try #require(c.discoveryAnswer(tag: 0x0403_0201))
        #expect(a.nodeType == .repeater && a.keyPrefix == key && a.snrThere == 5 && a.snrHere == 6 && a.rssi == -90)
        #expect(c.discoveryAnswer(tag: 7) == nil)   // someone else's check
    }

    @Test func aTraceComingBack() {
        // PUSH_CODE_TRACE_DATA: reserved, 4 bytes of path, flags 2, tag, auth, the hash, its SNR of us
        // (+6.0), ours of the way back (−5.0)
        let frame = Data([0x89, 0, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD, 24, UInt8(bitPattern: -20)])
        guard case .push(.traceData(let t))? = Codec.decode(frame) else { Issue.record("not a trace"); return }
        #expect(t.tag == 1 && t.hashes == Data([0xAA, 0xBB, 0xCC, 0xDD]) && t.snrs == [6] && t.finalSNR == -5)
    }
}

@Suite("Node location")
struct NodeLocationFrameTests {
    @Test func positionAndPolicyFrames() {
        // CMD_SET_ADVERT_LATLON: microdegrees, little-endian
        var w = ByteWriter(14)
        w.i32(50_500_000); w.i32(19_250_000)
        #expect(Codec.setAdvertPosition(Position(latitude: 50.5, longitude: 19.25)) == w.data)
        // CMD_SET_OTHER_PARAMS: the others sent back as they were, the location policy changed
        #expect(Codec.setOtherParams(OtherParams(manualAddContacts: 1, telemetryModes: 0x15, locationPolicy: 1, multiAcks: 2))
                == Data([38, 1, 0x15, 1, 2]))
    }
}

// Radio settings beyond the network: what the companion firmware's handlers expect (MyMesh.cpp).
@Suite("Radio settings frames")
struct RadioSettingsFrameTests {
    let pl = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)

    @Test func networkKeepsTheRepeatByte() {
        // without the byte (older firmware) the radio takes four parameters; with it, v9+ sets repeat too
        #expect(Codec.setRadio(pl).hex == "0b" + "f2440d00" + "24f40000" + "06" + "08")
        #expect(Codec.setRadio(pl, repeat: false).hex == "0b" + "f2440d00" + "24f40000" + "06" + "08" + "00")
        #expect(Codec.setRadio(pl, repeat: true).hex == "0b" + "f2440d00" + "24f40000" + "06" + "08" + "01")
    }

    @Test func settingFrames() {
        #expect(Codec.setTuning(TuningParams(rxDelayBase: 2.5, airtimeFactor: 1)).hex == "15" + "c4090000" + "e8030000")
        #expect(Codec.setTuning(TuningParams(rxDelayBase: -1, airtimeFactor: 0.0004)).hex == "15" + "00000000" + "00000000")
        #expect(Codec.getTuning().hex == "2b")
        #expect(Codec.setAutoAdd(AutoAddConfig(flags: 0x07, maxHops: 3)).hex == "3a0703")
        #expect(Codec.setAutoAdd(AutoAddConfig(flags: 0, maxHops: 200)).hex == "3a0040")   // at most 64
        #expect(Codec.getAutoAdd().hex == "3b")
        #expect(Codec.getRepeatFrequencies().hex == "3c")
        #expect(Codec.setPathHashMode(1).hex == "3d0001")
        #expect(Codec.setPathHashMode(7).hex == "3d0002")
        #expect(Codec.setCustomVar("gps", "1").hex == "29" + Data("gps:1".utf8).hex)
        #expect(Codec.factoryReset().hex == "33" + Data("reset".utf8).hex)
        #expect(Codec.setFloodScope(nil).hex == "3f")
        let scope = Codec.setFloodScope(FloodScope(name: "pl-sl", key: Data(repeating: 0xAB, count: 16)))
        #expect(scope.count == 1 + 31 + 16)
        #expect(scope.prefix(6).hex == "3f" + Data("pl-sl".utf8).hex)
        #expect(scope.dropFirst(6).prefix(26).allSatisfy { $0 == 0 })
        #expect(scope.suffix(16).allSatisfy { $0 == 0xAB })
    }

    @Test func settingReplies() {
        guard case .reply(.tuning(let t))? = Codec.decode(Data([23]) + Data([0xc4, 0x09, 0, 0, 0xe8, 0x03, 0, 0])) else { Issue.record("not tuning"); return }
        #expect(t == TuningParams(rxDelayBase: 2.5, airtimeFactor: 1))
        guard case .reply(.autoAdd(let a))? = Codec.decode(Data([25, 0x0d, 4])) else { Issue.record("not auto-add"); return }
        #expect(a.has(AutoAddConfig.overwriteOldest) && a.has(AutoAddConfig.repeaters) && a.has(AutoAddConfig.rooms) && !a.has(AutoAddConfig.people))
        #expect(a.maxHops == 4)
        guard case .reply(.repeatFrequencies(let none))? = Codec.decode(Data([26])) else { Issue.record("not frequencies"); return }
        #expect(none.isEmpty)
        var w = Data([26])
        for k: UInt32 in [433000, 433000, 869495, 869495, 918000, 918000] { w += withUnsafeBytes(of: k.littleEndian) { Data($0) } }
        guard case .reply(.repeatFrequencies(let three))? = Codec.decode(w) else { Issue.record("not frequencies"); return }
        #expect(three.count == 3)
        #expect(three[1].contains(mhz: 869.495) && !three[1].contains(mhz: 869.618))
        guard case .reply(.customVars(let vars))? = Codec.decode(Data([21]) + Data("gps:1,gps_interval:300".utf8)) else { Issue.record("not vars"); return }
        #expect(vars.map(\.name) == ["gps", "gps_interval"] && vars.map(\.value) == ["1", "300"])
        guard case .reply(.floodScope(let empty))? = Codec.decode(Data([28])) else { Issue.record("not a scope"); return }
        #expect(empty == nil)
        guard case .reply(.floodScope(let full))? = Codec.decode(Codec.setFloodScope(FloodScope(name: "pl-sl", key: Data(repeating: 1, count: 16))).dropFirst().reduce(into: Data([28])) { $0.append($1) }) else { Issue.record("not a scope"); return }
        #expect(full == FloodScope(name: "pl-sl", key: Data(repeating: 1, count: 16)))
    }

    @Test func telemetryModesPackTwoBitsEach() {
        let t = TelemetryModes(base: .everyone, location: .nobody, environment: .allowed)
        #expect(t.byte == 0b01_00_10)
        #expect(TelemetryModes(byte: t.byte) == t)
        #expect(TelemetryModes(byte: 0xff).base == .nobody)   // 3 isn't a mode
    }
}


@Suite("Telemetry")
struct TelemetryTests {
    @Test func requestAndAnswerFrames() throws {
        let key = PublicKey(Data(repeating: 0xAB, count: 32))!
        #expect(Codec.telemetryRequest(key) == Data([39, 0, 0, 0]) + key.bytes)
        let push = Data([0x8B, 0]) + key.prefix(6) + Data([1, 116, 0x01, 0x9C])
        guard case .push(.telemetryResponse(let prefix, let data))? = Codec.decode(push) else { Issue.record("not decoded"); return }
        #expect(prefix == key.prefix(6) && data == Data([1, 116, 0x01, 0x9C]))
    }

    @Test func readingsAsMeshCoreSendsThem() {
        // battery 4.12 V, board temperature -3.5 °C, humidity 45.5 %, pressure 1013.2 hPa on sensor channel 2
        let data = Data([1, 116, 0x01, 0x9C, 1, 103, 0xFF, 0xDD, 2, 104, 91, 2, 115, 0x27, 0x94])
        let r = Telemetry.decode(data)
        #expect(r.map(\.kind) == [.voltage, .temperature, .humidity, .pressure])
        #expect(r.map(\.channel) == [1, 1, 2, 2])
        #expect(r[0].values == [4.12] && r[1].values == [-3.5] && r[2].values == [45.5] && abs(r[3].values[0] - 1013.2) < 0.001)
    }

    @Test func positionsAndUnknownTypes() {
        // 50.0647, -6.1594 (west of Greenwich: negative), 312.45 m; then a type nobody knows, then more
        let gps = Data([1, 136, 0x7, 0xA3, 0xA7, 0xFF, 0xF, 0x66, 0x0, 0x7A, 0xD])
        let r = Telemetry.decode(gps + Data([1, 250, 1, 2, 3]) + Data([1, 116, 0x01, 0x9C]))
        #expect(r.count == 1)   // stops at the unknown type: its size isn't known
        #expect(abs(r[0].values[0] - 50.0647) < 0.00001 && abs(r[0].values[1] + 6.1594) < 0.00001 && abs(r[0].values[2] - 312.45) < 0.001)
        #expect(Telemetry.decode(Data([1, 116, 0x01])).isEmpty)   // cut off
    }
}
