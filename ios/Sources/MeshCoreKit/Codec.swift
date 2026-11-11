import Foundation

// The MeshCore companion protocol, from examples/companion_radio/MyMesh.cpp. Each frame starts with a
// code: commands (app → radio), replies (radio → app, codes below 0x80) and pushes (0x80 and up), sent
// whenever something happens.

enum Command: UInt8 {
    case appStart = 1, sendText = 2, sendChannelText = 3, getContacts = 4, getTime = 5, setTime = 6,
         sendAdvert = 7, setName = 8, addUpdateContact = 9, syncNextMessage = 10, setRadio = 11,
         setTxPower = 12, resetPath = 13, setAdvertPosition = 14, removeContact = 15, reboot = 19,
         getBattery = 20, deviceQuery = 22, sendLogin = 26, sendStatusRequest = 27, logout = 29,
         getContactByKey = 30, getChannel = 31, setChannel = 32, sendTracePath = 36, setDevicePin = 37, setOtherParams = 38,
         sendTelemetryRequest = 39,
         setTuning = 21, getCustomVars = 40, setCustomVar = 41, getTuning = 43,
         sendBinaryRequest = 50, factoryReset = 51,
         sendControlData = 55, setAutoAdd = 58, getAutoAdd = 59, getRepeatFrequencies = 60, setPathHashMode = 61,
         setFloodScope = 63, getFloodScope = 64, runCommand = 66
}

enum ReplyCode: UInt8 {
    case ok = 0, error = 1, contactsStart = 2, contact = 3, endOfContacts = 4, selfInfo = 5, sent = 6,
         contactMessage = 7, channelMessage = 8, currentTime = 9, noMoreMessages = 10, battery = 12,
         deviceInfo = 13, disabled = 15, contactMessageV3 = 16, channelMessageV3 = 17, channelInfo = 18,
         customVars = 21, tuning = 23, autoAdd = 25, repeatFrequencies = 26, floodScope = 28, commandReply = 29
}

enum PushCode: UInt8 {
    case advert = 0x80, pathUpdated = 0x81, sendConfirmed = 0x82, messagesWaiting = 0x83,
         loginSuccess = 0x85, loginFail = 0x86, statusResponse = 0x87, rxLog = 0x88, traceData = 0x89, newAdvert = 0x8A,
         telemetryResponse = 0x8B,
         binaryResponse = 0x8C, controlData = 0x8E, contactDeleted = 0x8F, contactsFull = 0x90
}

/// Why the radio refused a command.
public enum RadioError: Error, Hashable, Sendable, CustomStringConvertible {
    case unsupported, notFound, tableFull, badState, fileIO, illegalArgument, unknown(UInt8)
    /// no reply in time
    case timeout
    /// the connection dropped while waiting
    case disconnected
    /// a reply that couldn't be read
    case malformed

    init(code: UInt8) {
        self = switch code {
        case 1: .unsupported
        case 2: .notFound
        case 3: .tableFull
        case 4: .badState
        case 5: .fileIO
        case 6: .illegalArgument
        default: .unknown(code)
        }
    }

    public var description: String {
        switch self {
        case .unsupported: String(localized: "The radio doesn't support that.")
        case .notFound: String(localized: "The radio doesn't have that contact or channel.")
        case .tableFull: String(localized: "The radio's table is full.")
        case .badState: String(localized: "The radio is busy with something else.")
        case .fileIO: String(localized: "The radio couldn't save it.")
        case .illegalArgument: String(localized: "The radio rejected the value.")
        case .unknown(let c): String(localized: "The radio returned error \(Int(c)).")
        case .timeout: String(localized: "The radio didn't answer in time.")
        case .disconnected: String(localized: "The connection to the radio dropped.")
        case .malformed: String(localized: "The radio's answer couldn't be read.")
        }
    }
}

/// A reply to a command.
enum Reply: Sendable {
    case ok
    case error(RadioError)
    case contactsStart(count: Int)
    case contact(Contact)
    case endOfContacts(lastModified: UInt32)
    case selfInfo(SelfInfo)
    case sent(SentInfo)
    case message(ReceivedMessage)
    case noMoreMessages
    case currentTime(UInt32)
    case battery(BatteryInfo)
    case deviceInfo(DeviceInfo)
    case channelInfo(ChannelInfo)
    case disabled
    case customVars([(name: String, value: String)])
    case tuning(TuningParams)
    case autoAdd(AutoAddConfig)
    case repeatFrequencies([FrequencyRange])
    case floodScope(FloodScope?)
    case commandReply(String)
    case other(code: UInt8, data: Data)
}

/// Something the radio reports on its own.
public enum MeshEvent: Sendable {
    /// a contact's advert arrived (the contact list changed)
    case advert(PublicKey)
    /// a new node advertised, and the radio adds contacts only by hand
    case newAdvert(Contact)
    /// the radio stored a new route to this contact
    case pathUpdated(PublicKey)
    /// a DM's ACK arrived: its code, and the round trip in ms
    case sendConfirmed(ack: UInt32, roundTripMs: UInt32)
    /// messages are waiting in the radio's queue
    case messagesWaiting
    case loginSuccess(LoginResult)
    case loginFailed(keyPrefix: Data)
    /// a node's status (the bytes of its stats)
    case statusResponse(keyPrefix: Data, data: Data)
    /// a node's readings (Cayenne LPP: battery, temperature, location…), answering a telemetry request
    case telemetryResponse(keyPrefix: Data, data: Data)
    /// a reply to a binary request, matched by its tag
    case binaryResponse(tag: UInt32, data: Data)
    case contactDeleted(PublicKey)
    case contactsFull
    /// every packet the radio hears
    case rxLog(RxLogEntry)
    /// a trace came back: the SNR at each hop, and here
    case traceData(TraceResult)
    /// a control packet heard straight from a node (node discovery answers)
    case controlData(ControlData)
    /// a message another app on this radio fetched from the queue (several apps see every reply)
    case messageForAnotherApp(ReceivedMessage)
    /// the connection ended (with why, if it failed)
    case disconnected(String?)
    case other(code: UInt8, data: Data)
}

enum Frame {
    case reply(Reply)
    case push(MeshEvent)
}

enum Codec {
    static func decode(_ frame: Data) -> Frame? {
        var r = ByteReader(frame)
        guard let code = try? r.u8() else { return nil }
        do {
            if code >= 0x80 { return .push(try decodePush(code, &r, frame)) }
            return .reply(try decodeReply(code, &r, frame))
        } catch {
            return code >= 0x80 ? .push(.other(code: code, data: frame)) : .reply(.other(code: code, data: frame))
        }
    }

    // MARK: replies

    static func decodeReply(_ code: UInt8, _ r: inout ByteReader, _ frame: Data) throws -> Reply {
        guard let c = ReplyCode(rawValue: code) else { return .other(code: code, data: frame) }
        switch c {
        case .ok: return .ok
        case .error: return .error(RadioError(code: r.remaining > 0 ? try r.u8() : 0))
        case .contactsStart: return .contactsStart(count: Int(try r.u32()))
        case .contact: return .contact(try contact(&r))
        case .endOfContacts: return .endOfContacts(lastModified: r.remaining >= 4 ? try r.u32() : 0)
        case .selfInfo: return .selfInfo(try selfInfo(&r))
        case .sent:
            let flood = try r.u8() == 1
            return .sent(SentInfo(flood: flood, tag: try r.u32(), timeoutMs: try r.u32()))
        case .contactMessage, .contactMessageV3: return .message(.contact(try contactMessage(&r, v3: c == .contactMessageV3)))
        case .channelMessage, .channelMessageV3: return .message(.channel(try channelMessage(&r, v3: c == .channelMessageV3)))
        case .noMoreMessages: return .noMoreMessages
        case .currentTime: return .currentTime(try r.u32())
        case .battery:
            return .battery(BatteryInfo(millivolts: Int(try r.u16()), storageUsedKB: Int(try r.u32()), storageTotalKB: Int(try r.u32())))
        case .deviceInfo: return .deviceInfo(try deviceInfo(&r))
        case .channelInfo:
            let index = Int(try r.u8())
            return .channelInfo(ChannelInfo(index: index, name: try r.string(32), secret: try r.bytes(16)))
        case .disabled: return .disabled
        case .customVars:
            // "name:value,name:value"
            let text = r.restString()
            return .customVars(text.split(separator: ",").compactMap { pair in
                guard let colon = pair.firstIndex(of: ":") else { return nil }
                return (String(pair[..<colon]), String(pair[pair.index(after: colon)...]))
            })
        case .tuning:
            return .tuning(TuningParams(rxDelayBase: Double(try r.u32()) / 1000, airtimeFactor: Double(try r.u32()) / 1000))
        case .autoAdd:
            let flags = try r.u8()
            return .autoAdd(AutoAddConfig(flags: flags, maxHops: r.remaining > 0 ? Int(try r.u8()) : 0))
        case .repeatFrequencies:
            var ranges: [FrequencyRange] = []
            while r.remaining >= 8 { ranges.append(FrequencyRange(lowerKHz: try r.u32(), upperKHz: try r.u32())) }
            return .repeatFrequencies(ranges)
        case .floodScope:
            guard r.remaining >= 31 + 16 else { return .floodScope(nil) }
            let name = try r.string(31)
            return .floodScope(FloodScope(name: name, key: try r.bytes(16)))
        case .commandReply: return .commandReply(r.restString())
        }
    }

    static func contact(_ r: inout ByteReader) throws -> Contact {
        guard let key = PublicKey(try r.bytes(32)) else { throw RadioError.malformed }
        let type = NodeType(raw: try r.u8()), flags = try r.u8(), pathLength = try r.u8()
        let path = try r.bytes(64)
        let name = try r.string(32), lastAdvert = try r.u32()
        let lat = try r.i32(), lon = try r.i32()
        let lastMod = r.remaining >= 4 ? try r.u32() : 0
        return Contact(key: key, type: type, flags: flags, outPath: OutPath.decode(lengthByte: pathLength, path: path), name: name,
                       lastAdvert: lastAdvert, position: Position(microdegreesLat: lat, lon: lon), lastModified: lastMod)
    }

    static func selfInfo(_ r: inout ByteReader) throws -> SelfInfo {
        _ = try r.u8()   // advert type
        let tx = Int(try r.i8()), maxTx = Int(try r.u8())
        guard let key = PublicKey(try r.bytes(32)) else { throw RadioError.malformed }
        let lat = try r.i32(), lon = try r.i32()
        let multiAcks = try r.u8()
        let locPolicy = try r.u8()
        let telemetry = try r.u8()
        let manualRaw = try r.u8()
        let manual = manualRaw & 1 == 1
        let freq = Double(try r.u32()) / 1000, bw = Double(try r.u32()) / 1000
        let sf = Int(try r.u8()), cr = Int(try r.u8())
        return SelfInfo(key: key, name: r.restString(), txPower: tx, maxTxPower: maxTx, position: Position(microdegreesLat: lat, lon: lon),
                        radio: RadioSettings(frequencyMHz: freq, bandwidthKHz: bw, spreadingFactor: sf, codingRate: cr),
                        advertLocationPolicy: locPolicy, manualAddContacts: manual,
                        otherParams: OtherParams(manualAddContacts: manualRaw, telemetryModes: telemetry, locationPolicy: locPolicy, multiAcks: multiAcks))
    }

    static func deviceInfo(_ r: inout ByteReader) throws -> DeviceInfo {
        let fw = Int(try r.u8()), maxContacts = Int(try r.u8()) * 2, maxChannels = Int(try r.u8())
        let pin = try r.u32()
        let date = try r.string(12), model = try r.string(40), version = try r.string(20)
        let repeatOn: Bool? = r.remaining >= 1 ? try r.u8() == 1 : nil
        let hashMode: Int? = r.remaining >= 1 ? Int(try r.u8()) : nil
        return DeviceInfo(firmwareCode: fw, maxContacts: maxContacts, maxChannels: maxChannels, blePin: pin, buildDate: date,
                          model: model, version: version, repeatEnabled: repeatOn, pathHashMode: hashMode)
    }

    /// The path length byte of a received message: 0xFF means it came direct.
    static func hops(_ b: UInt8) -> (hops: Int?, size: Int) {
        b == 0xFF ? (nil, 1) : (Int(b & 0x3F), Int(b >> 6) + 1)
    }

    static func contactMessage(_ r: inout ByteReader, v3: Bool) throws -> ContactMessage {
        var snr: Double?
        if v3 { snr = Double(try r.i8()) / 4; _ = try r.bytes(2) }
        let prefix = try r.bytes(6)
        let (hops, size) = hops(try r.u8())
        // the text type as a number (0 plain, 1 a command's answer, 2 a signed room post), not the
        // packet's flags byte: the radio has already taken it out of that
        let type = TextType(rawValue: try r.u8()) ?? .plain
        let ts = try r.u32()
        let author: Data? = type == .signedPlain ? try r.bytes(4) : nil
        return ContactMessage(senderPrefix: prefix, snr: snr, floodHops: hops, pathHashSize: size, textType: type,
                              senderTimestamp: ts, authorPrefix: author, text: r.restString())
    }

    static func channelMessage(_ r: inout ByteReader, v3: Bool) throws -> ChannelMessage {
        var snr: Double?
        if v3 { snr = Double(try r.i8()) / 4; _ = try r.bytes(2) }
        let index = Int(try r.u8())
        let (hops, size) = hops(try r.u8())
        let type = TextType(rawValue: try r.u8()) ?? .plain
        return ChannelMessage(channelIndex: index, snr: snr, floodHops: hops, pathHashSize: size, textType: type,
                              senderTimestamp: try r.u32(), text: r.restString())
    }

    // MARK: pushes

    static func decodePush(_ code: UInt8, _ r: inout ByteReader, _ frame: Data) throws -> MeshEvent {
        guard let c = PushCode(rawValue: code) else { return .other(code: code, data: frame) }
        func key() throws -> PublicKey {
            guard let k = PublicKey(try r.bytes(32)) else { throw RadioError.malformed }
            return k
        }
        switch c {
        case .advert: return .advert(try key())
        case .pathUpdated: return .pathUpdated(try key())
        case .newAdvert: return .newAdvert(try contact(&r))
        case .sendConfirmed:
            let ack = try r.u32()
            return .sendConfirmed(ack: ack, roundTripMs: r.remaining >= 4 ? try r.u32() : 0)
        case .messagesWaiting: return .messagesWaiting
        case .loginSuccess:
            let perms = try r.u8(), prefix = try r.bytes(6)
            let ts: UInt32? = r.remaining >= 4 ? try r.u32() : nil
            let acl: UInt8? = r.remaining >= 1 ? try r.u8() & 0x03 : nil
            let fw: UInt8? = r.remaining >= 1 ? try r.u8() : nil
            return .loginSuccess(LoginResult(keyPrefix: prefix, permissions: perms, serverTime: ts, aclRole: acl, firmwareLevel: fw))
        case .loginFail:
            _ = try r.u8()
            return .loginFailed(keyPrefix: try r.bytes(6))
        case .statusResponse:
            _ = try r.u8()
            let prefix = try r.bytes(6)
            return .statusResponse(keyPrefix: prefix, data: r.rest())
        case .telemetryResponse:
            _ = try r.u8()
            let prefix = try r.bytes(6)
            return .telemetryResponse(keyPrefix: prefix, data: r.rest())
        case .rxLog:
            let snr = Double(try r.i8()) / 4, rssi = Int(try r.i8())
            return .rxLog(RxLogEntry(snr: snr, rssi: rssi, raw: r.rest()))
        case .traceData:
            _ = try r.u8()   // reserved
            let len = Int(try r.u8()), flags = try r.u8()
            let tag = try r.u32(), auth = try r.u32()
            let hashes = try r.bytes(len)
            let count = len >> Int(flags & 0x03)
            let snrs = try (0..<count).map { _ in Double(try r.i8()) / 4 }
            return .traceData(TraceResult(tag: tag, auth: auth, flags: flags, hashes: hashes, snrs: snrs, finalSNR: Double(try r.i8()) / 4))
        case .controlData:
            let snr = Double(try r.i8()) / 4, rssi = Int(try r.i8()), pathLength = Int(try r.u8())
            return .controlData(ControlData(snr: snr, rssi: rssi, pathLength: pathLength, payload: r.rest()))
        case .binaryResponse:
            _ = try r.u8()
            let tag = try r.u32()
            return .binaryResponse(tag: tag, data: r.rest())
        case .contactDeleted: return .contactDeleted(try key())
        case .contactsFull: return .contactsFull
        }
    }

    // MARK: commands

    static let maxText = 150

    static func deviceQuery(protocolVersion: UInt8 = 3) -> Data {
        var w = ByteWriter(Command.deviceQuery.rawValue); w.u8(protocolVersion); return w.data
    }

    static func appStart(name: String) -> Data {
        var w = ByteWriter(Command.appStart.rawValue)
        w.bytes(Data([3, 0, 0, 0, 0, 0, 0]))   // reserved
        w.text(name, maxBytes: 32)
        return w.data
    }

    static func getContacts(since: UInt32?) -> Data {
        var w = ByteWriter(Command.getContacts.rawValue); if let since { w.u32(since) }; return w.data
    }

    static func getChannel(_ index: Int) -> Data { Data([Command.getChannel.rawValue, UInt8(index)]) }

    static func setChannel(_ index: Int, name: String, secret: Data) -> Data {
        var w = ByteWriter(Command.setChannel.rawValue)
        w.u8(UInt8(index)); w.string(name, size: 32)
        var s = secret.prefix(16); s.append(Data(count: 16 - s.count)); w.bytes(s)
        return w.data
    }

    static func syncNextMessage() -> Data { Data([Command.syncNextMessage.rawValue]) }

    static func sendText(to key: PublicKey, text: String, timestamp: UInt32, attempt: Int, type: TextType = .plain) -> Data {
        var w = ByteWriter(Command.sendText.rawValue)
        w.u8(type.rawValue); w.u8(UInt8(attempt & 0x03)); w.u32(timestamp); w.bytes(key.prefix(6))
        w.text(text, maxBytes: maxText)
        return w.data
    }

    static func sendChannelText(channel: Int, text: String, timestamp: UInt32) -> Data {
        var w = ByteWriter(Command.sendChannelText.rawValue)
        w.u8(TextType.plain.rawValue); w.u8(UInt8(channel)); w.u32(timestamp)
        w.text(text, maxBytes: maxText)
        return w.data
    }

    static func sendAdvert(flood: Bool) -> Data { Data([Command.sendAdvert.rawValue, flood ? 1 : 0]) }

    static func setName(_ name: String) -> Data {
        var w = ByteWriter(Command.setName.rawValue); w.text(name, maxBytes: 31); return w.data
    }

    static func setTime(_ t: UInt32) -> Data { var w = ByteWriter(Command.setTime.rawValue); w.u32(t); return w.data }
    static func getTime() -> Data { Data([Command.getTime.rawValue]) }

    static func resetPath(_ key: PublicKey) -> Data { Data([Command.resetPath.rawValue]) + key.bytes }
    static func removeContact(_ key: PublicKey) -> Data { Data([Command.removeContact.rawValue]) + key.bytes }
    static func getContact(_ key: PublicKey) -> Data { Data([Command.getContactByKey.rawValue]) + key.bytes }

    /// The whole record, position included (0,0 for none): for a new contact the radio starts from
    /// uninitialised memory, so a field left out of the frame comes out as garbage.
    /// The whole contact record. With `lastModified`, the radio keeps that as when it last changed (else it
    /// takes now, which makes the contact look freshly heard to "make room" and tidying).
    static func addUpdateContact(_ c: Contact, lastModified: UInt32? = nil) -> Data {
        var w = ByteWriter(Command.addUpdateContact.rawValue)
        w.bytes(c.key.bytes); w.u8(c.type.rawValue); w.u8(c.flags)
        w.u8(c.outPath?.lengthByte ?? 0xFF)
        var p = c.outPath?.bytes ?? Data(); p.append(Data(count: max(0, 64 - p.count))); w.bytes(p.prefix(64))
        w.string(c.name, size: 32)
        w.u32(c.lastAdvert)
        w.i32(Int32((c.position?.latitude ?? 0) * 1e6)); w.i32(Int32((c.position?.longitude ?? 0) * 1e6))
        if let lastModified { w.u32(lastModified) }
        return w.data
    }

    /// The LoRa parameters, and (firmware v9+) whether the radio repeats other nodes' packets itself: left
    /// out (nil) for older firmware, which takes the four parameters only.
    static func setRadio(_ s: RadioSettings, repeat repeating: Bool? = nil) -> Data {
        var w = ByteWriter(Command.setRadio.rawValue)
        w.u32(UInt32((s.frequencyMHz * 1000).rounded())); w.u32(UInt32((s.bandwidthKHz * 1000).rounded()))
        w.u8(UInt8(s.spreadingFactor)); w.u8(UInt8(s.codingRate))
        if let repeating { w.u8(repeating ? 1 : 0) }
        return w.data
    }

    static func getTuning() -> Data { Data([Command.getTuning.rawValue]) }
    static func setTuning(_ t: TuningParams) -> Data {
        var w = ByteWriter(Command.setTuning.rawValue)
        w.u32(UInt32((max(0, t.rxDelayBase) * 1000).rounded())); w.u32(UInt32((max(0, t.airtimeFactor) * 1000).rounded()))
        return w.data
    }
    static func getAutoAdd() -> Data { Data([Command.getAutoAdd.rawValue]) }
    static func setAutoAdd(_ a: AutoAddConfig) -> Data { Data([Command.setAutoAdd.rawValue, a.flags, UInt8(min(64, max(0, a.maxHops)))]) }
    static func getRepeatFrequencies() -> Data { Data([Command.getRepeatFrequencies.rawValue]) }
    /// 0, 1 or 2: path hashes of 1, 2 or 3 bytes
    static func setPathHashMode(_ mode: Int) -> Data { Data([Command.setPathHashMode.rawValue, 0, UInt8(min(2, max(0, mode)))]) }
    static func getCustomVars() -> Data { Data([Command.getCustomVars.rawValue]) }
    static func setCustomVar(_ name: String, _ value: String) -> Data { Data([Command.setCustomVar.rawValue]) + Data("\(name):\(value)".utf8) }
    static func getFloodScope() -> Data { Data([Command.getFloodScope.rawValue]) }
    /// A region (name up to 30 bytes, NUL-padded to 31, then its 16-byte key), or none: the bare command.
    static func setFloodScope(_ s: FloodScope?) -> Data {
        guard let s else { return Data([Command.setFloodScope.rawValue]) }
        var w = ByteWriter(Command.setFloodScope.rawValue)
        w.string(s.name, size: 31)
        w.bytes(s.key.prefix(16) + Data(count: max(0, 16 - s.key.count)))
        return w.data
    }
    static func runCommand(_ text: String) -> Data { Data([Command.runCommand.rawValue]) + Data(text.utf8) }
    static func factoryReset() -> Data { Data([Command.factoryReset.rawValue]) + Data("reset".utf8) }

    static func setTxPower(_ dbm: Int) -> Data { Data([Command.setTxPower.rawValue, UInt8(bitPattern: Int8(clamping: dbm))]) }
    static func getBattery() -> Data { Data([Command.getBattery.rawValue]) }
    static func reboot() -> Data { Data([Command.reboot.rawValue]) + Data("reboot".utf8) }
    static func setDevicePin(_ pin: UInt32) -> Data { var w = ByteWriter(Command.setDevicePin.rawValue); w.u32(pin); return w.data }

    static func login(_ key: PublicKey, password: String) -> Data {
        var w = ByteWriter(Command.sendLogin.rawValue); w.bytes(key.bytes); w.text(password, maxBytes: 15); return w.data
    }
    static func statusRequest(_ key: PublicKey) -> Data { Data([Command.sendStatusRequest.rawValue]) + key.bytes }
    /// A node's readings. The first of the three spare bytes is a mask of what not to send (0: everything
    /// it allows).
    static func telemetryRequest(_ key: PublicKey) -> Data { Data([Command.sendTelemetryRequest.rawValue, 0, 0, 0]) + key.bytes }
    static func logout(_ key: PublicKey) -> Data { Data([Command.logout.rawValue]) + key.bytes }
    static func binaryRequest(_ key: PublicKey, _ body: Data) -> Data { Data([Command.sendBinaryRequest.rawValue]) + key.bytes + body }

    /// The node's position, as its adverts share it (when its location policy shares one).
    static func setAdvertPosition(_ p: Position) -> Data {
        var w = ByteWriter(Command.setAdvertPosition.rawValue)
        w.i32(Int32((p.latitude * 1_000_000).rounded()))
        w.i32(Int32((p.longitude * 1_000_000).rounded()))
        return w.data
    }

    /// Contacts by hand, telemetry, location policy and multiple ACKs, all at once (as the radio takes them).
    static func setOtherParams(_ o: OtherParams) -> Data {
        Data([Command.setOtherParams.rawValue, o.manualAddContacts, o.telemetryModes, o.locationPolicy, o.multiAcks])
    }

    /// "Which repeaters hear me?": a node-discovery request, sent zero-hop (never passed on). Repeaters in
    /// earshot answer with their SNR of it; prefix_only (bit 0) asks for 8 bytes of their key.
    static func discoverRepeaters(tag: UInt32) -> Data {
        var w = ByteWriter(Command.sendControlData.rawValue)
        w.u8(ControlData.discoverRequest | 0x01)   // prefix only
        w.u8(1 << 2)                               // repeaters (ADV_TYPE_REPEATER = 2)
        w.u32(tag)
        return w.data
    }

    /// A trace along `path` (repeater key prefixes, `1 << (flags & 3)` bytes each): each repeater adds
    /// how well it heard it, and it comes back.
    static func trace(tag: UInt32, auth: UInt32 = 0, flags: UInt8, path: Data) -> Data {
        var w = ByteWriter(Command.sendTracePath.rawValue)
        w.u32(tag); w.u32(auth); w.u8(flags); w.bytes(path)
        return w.data
    }
}
