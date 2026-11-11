import Foundation

/// Talks to a MeshCore companion radio over any transport.
///
/// One command is in flight at a time, and it completes only on the reply codes it expects: a radio with
/// several apps attached (MeshChat's firmware runs its own web app beside Bluetooth and WiFi) sends every
/// reply to every app, so another app's replies must not complete ours. Pushes, and messages another app
/// fetched from the radio's queue, arrive on `events`.
public actor MeshCoreClient {
    public nonisolated let transport: MeshTransport
    public nonisolated let events: AsyncStream<MeshEvent>
    private let eventSink: AsyncStream<MeshEvent>.Continuation

    public private(set) var device: DeviceInfo?
    public private(set) var me: SelfInfo?

    /// The least time to wait for a remote node's answer over the mesh (shorter in tests).
    public nonisolated let minimumRemoteWait: Duration

    public init(transport: MeshTransport, minimumRemoteWait: Duration = .seconds(8)) {
        self.transport = transport
        self.minimumRemoteWait = minimumRemoteWait
        (events, eventSink) = AsyncStream.makeStream(of: MeshEvent.self, bufferingPolicy: .bufferingNewest(1000))
    }

    // MARK: connection

    private var reader: Task<Void, Never>?

    /// Connects, asks for protocol v3 frames (they carry SNR) and identifies the app.
    @discardableResult
    public func start(appName: String = "MeshChat") async throws -> (DeviceInfo, SelfInfo) {
        try await transport.connect()
        let frames = transport.frames
        reader = Task { [weak self] in
            do {
                for try await frame in frames { await self?.handle(frame) }
                await self?.closed(nil)
            } catch {
                await self?.closed(error)
            }
        }
        let d = try await deviceQuery()
        let s = try await appStart(name: appName)
        return (d, s)
    }

    public func stop() {
        transport.disconnect()
        reader?.cancel()
    }

    private func closed(_ error: Error?) {
        failPending(RadioError.disconnected)
        for w in eventWaiters.values { w.cont.resume(throwing: RadioError.disconnected) }
        eventWaiters.removeAll()
        eventSink.yield(.disconnected(error.map { "\($0)" }))
        eventSink.finish()
    }

    // MARK: one command at a time

    /// What a pending command does with a reply.
    enum Take { case ignore, collect, finish }

    private struct Pending {
        let id: Int
        let classify: @Sendable (Reply) -> Take
        var collected: [Reply]
        let cont: CheckedContinuation<[Reply], Error>
    }

    private var pending: Pending?
    private var nextID = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    /// Sends a command and collects its replies until `classify` says it's finished.
    func exchange(_ frame: Data, timeout: Duration = .seconds(8), _ classify: @escaping @Sendable (Reply) -> Take) async throws -> [Reply] {
        await acquire()
        defer { release() }
        nextID += 1
        let id = nextID
        let transport = self.transport
        return try await withCheckedThrowingContinuation { cont in
            pending = Pending(id: id, classify: classify, collected: [], cont: cont)
            Task {
                do { try await transport.send(frame) } catch { self.finish(id, .failure(error)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.finish(id, .failure(RadioError.timeout))
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<[Reply], Error>) {
        guard let p = pending, p.id == id else { return }
        pending = nil
        p.cont.resume(with: result)
    }

    private func failPending(_ e: Error) {
        if let p = pending { pending = nil; p.cont.resume(throwing: e) }
    }

    /// One reply of the expected kind (or the radio's error).
    func single(_ frame: Data, timeout: Duration = .seconds(8), _ accept: @escaping @Sendable (Reply) -> Bool) async throws -> Reply {
        let replies = try await exchange(frame, timeout: timeout) { r in
            if case .error = r { return .finish }
            return accept(r) ? .finish : .ignore
        }
        guard let r = replies.last else { throw RadioError.malformed }
        if case .error(let e) = r { throw e }
        return r
    }

    /// For commands answered with OK (or an error).
    func expectOK(_ frame: Data) async throws {
        _ = try await single(frame) { if case .ok = $0 { true } else { false } }
    }

    // MARK: incoming frames

    /// pushes gathered for a while (answers that come from several nodes)
    private var gathering: [Int: [MeshEvent]] = [:]

    /// Every push that matches, for `duration`.
    public func gather<T: Sendable>(for duration: Duration, _ match: @escaping @Sendable (MeshEvent) -> T?) async -> [T] {
        nextID += 1
        let id = nextID
        gathering[id] = []
        try? await Task.sleep(for: duration)
        let events = gathering.removeValue(forKey: id) ?? []
        return events.compactMap(match)
    }

    private func handle(_ frame: Data) {
        switch Codec.decode(frame) {
        case .push(let e)?:
            for id in gathering.keys { gathering[id]?.append(e) }
            for (id, w) in eventWaiters {
                if let v = w.match(e) { eventWaiters[id] = nil; w.cont.resume(returning: v) }
            }
            eventSink.yield(e)
        case .reply(let r)?:
            if var p = pending {
                switch p.classify(r) {
                case .ignore: unsolicited(r)
                case .collect: p.collected.append(r); pending = p
                case .finish: p.collected.append(r); pending = p; finish(p.id, .success(p.collected))
                }
            } else {
                unsolicited(r)
            }
        case nil: break
        }
    }

    /// A reply to someone else's command. Messages are worth keeping: the other app has taken them off
    /// the radio's queue, so this is the only chance to see them.
    private func unsolicited(_ r: Reply) {
        if case .message(let m) = r { eventSink.yield(.messageForAnotherApp(m)) }
    }

    // MARK: waiting for pushes (login answers, statuses, binary replies)

    private struct EventWaiter {
        let match: @Sendable (MeshEvent) -> (any Sendable)?
        let cont: CheckedContinuation<any Sendable, Error>
    }

    private var eventWaiters: [Int: EventWaiter] = [:]

    /// The first push `match` accepts, within `timeout`.
    public func waitFor<T: Sendable>(timeout: Duration, _ match: @escaping @Sendable (MeshEvent) -> T?) async throws -> T {
        nextID += 1
        let id = nextID
        let v = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<any Sendable, Error>) in
            eventWaiters[id] = EventWaiter(match: { match($0) }, cont: cont)
            Task {
                try? await Task.sleep(for: timeout)
                self.expireWaiter(id)
            }
        }
        guard let t = v as? T else { throw RadioError.malformed }
        return t
    }

    private func expireWaiter(_ id: Int) {
        if let w = eventWaiters.removeValue(forKey: id) { w.cont.resume(throwing: RadioError.timeout) }
    }
}

// MARK: - Commands

extension MeshCoreClient {
    public func deviceQuery() async throws -> DeviceInfo {
        guard case .deviceInfo(let d) = try await single(Codec.deviceQuery(), { if case .deviceInfo = $0 { true } else { false } })
        else { throw RadioError.malformed }
        device = d
        return d
    }

    public func appStart(name: String) async throws -> SelfInfo {
        guard case .selfInfo(let s) = try await single(Codec.appStart(name: name), { if case .selfInfo = $0 { true } else { false } })
        else { throw RadioError.malformed }
        me = s
        return s
    }

    /// The contact list (only those changed since `since`, the radio's clock, if given), and the newest
    /// change time to pass next time.
    public func contacts(since: UInt32? = nil) async throws -> (contacts: [Contact], lastModified: UInt32) {
        let started = Flag()
        let replies = try await exchange(Codec.getContacts(since: since), timeout: .seconds(90)) { r in
            switch r {
            case .contactsStart: started.set(); return .collect
            case .contact: return started.isSet ? .collect : .ignore
            case .endOfContacts: return started.isSet ? .finish : .ignore
            case .error: return .finish
            default: return .ignore
            }
        }
        var list: [Contact] = []
        var last: UInt32 = 0
        for r in replies {
            switch r {
            case .contact(let c): list.append(c)
            case .endOfContacts(let t): last = t
            case .error(let e): throw e
            default: break
            }
        }
        return (list, last)
    }

    public func contact(_ key: PublicKey) async throws -> Contact? {
        do {
            guard case .contact(let c) = try await single(Codec.getContact(key), {
                if case .contact(let c) = $0 { c.key == key } else { false }
            }) else { return nil }
            return c
        } catch RadioError.notFound { return nil }
    }

    /// A channel slot (nil when the radio has no such slot).
    public func channel(_ index: Int) async throws -> ChannelInfo? {
        do {
            guard case .channelInfo(let c) = try await single(Codec.getChannel(index), {
                if case .channelInfo(let c) = $0 { c.index == index } else { false }
            }) else { return nil }
            return c
        } catch RadioError.notFound { return nil }
    }

    /// Every channel slot in use.
    public func channels() async throws -> [ChannelInfo] {
        let n = device?.maxChannels ?? 8
        var out: [ChannelInfo] = []
        for i in 0..<n {
            if let c = try await channel(i), !c.isEmpty { out.append(c) }
        }
        return out
    }

    /// Puts a channel in a slot; an empty name and key frees it.
    public func setChannel(_ index: Int, name: String, secret: Data) async throws {
        try await expectOK(Codec.setChannel(index, name: name, secret: secret))
    }

    /// The next message from the radio's queue, or nil when it's empty.
    public func nextMessage() async throws -> ReceivedMessage? {
        let r = try await single(Codec.syncNextMessage()) {
            switch $0 { case .message, .noMoreMessages: true; default: false }
        }
        if case .message(let m) = r { return m }
        return nil
    }

    /// Sends a DM. `attempt` (0–3) is part of the packet, so a retry isn't a duplicate. The radio floods it
    /// when it has no saved route.
    /// Runs a command on a repeater or room server we're logged in to as admin. No ACK: the answer comes
    /// back as a CLI_DATA message.
    public func sendCommand(to key: PublicKey, _ text: String) async throws -> SentInfo {
        let frame = Codec.sendText(to: key, text: text, timestamp: UInt32(Date().timeIntervalSince1970), attempt: 0, type: .cliData)
        guard case .sent(let s) = try await single(frame, { if case .sent = $0 { true } else { false } }) else { throw RadioError.malformed }
        return s
    }

    public func sendText(to key: PublicKey, text: String, timestamp: UInt32, attempt: Int = 0) async throws -> SentInfo {
        guard case .sent(let s) = try await single(Codec.sendText(to: key, text: text, timestamp: timestamp, attempt: attempt), {
            if case .sent = $0 { true } else { false }
        }) else { throw RadioError.malformed }
        return s
    }

    /// Sends a channel message; the radio adds "Your name: ". Same timestamp on a retry: the same packet.
    public func sendChannelText(channel: Int, text: String, timestamp: UInt32) async throws {
        try await expectOK(Codec.sendChannelText(channel: channel, text: text, timestamp: timestamp))
    }

    public func sendAdvert(flood: Bool) async throws { try await expectOK(Codec.sendAdvert(flood: flood)) }
    public func setName(_ name: String) async throws { try await expectOK(Codec.setName(name)) }
    public func setTime(_ t: UInt32) async throws { try await expectOK(Codec.setTime(t)) }

    public func time() async throws -> UInt32 {
        guard case .currentTime(let t) = try await single(Codec.getTime(), { if case .currentTime = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return t
    }

    /// Forgets the saved route: the next message floods and learns a fresh one.
    public func resetPath(_ key: PublicKey) async throws { try await expectOK(Codec.resetPath(key)) }
    public func addOrUpdate(_ c: Contact, lastModified: UInt32? = nil) async throws {
        try await expectOK(Codec.addUpdateContact(c, lastModified: lastModified))
    }
    public func remove(_ key: PublicKey) async throws { try await expectOK(Codec.removeContact(key)) }
    public func setRadio(_ s: RadioSettings, repeat repeating: Bool? = nil) async throws { try await expectOK(Codec.setRadio(s, repeat: repeating)) }

    public func tuning() async throws -> TuningParams {
        guard case .tuning(let t) = try await single(Codec.getTuning(), { if case .tuning = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return t
    }
    public func setTuning(_ t: TuningParams) async throws { try await expectOK(Codec.setTuning(t)) }

    public func autoAdd() async throws -> AutoAddConfig {
        guard case .autoAdd(let a) = try await single(Codec.getAutoAdd(), { if case .autoAdd = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return a
    }
    public func setAutoAdd(_ a: AutoAddConfig) async throws { try await expectOK(Codec.setAutoAdd(a)) }

    /// Where the radio may repeat other nodes' packets (firmware v9+).
    public func repeatFrequencies() async throws -> [FrequencyRange] {
        guard case .repeatFrequencies(let f) = try await single(Codec.getRepeatFrequencies(), { if case .repeatFrequencies = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return f
    }

    /// 0, 1 or 2: the radio's own path hashes of 1, 2 or 3 bytes.
    public func setPathHashMode(_ mode: Int) async throws { try await expectOK(Codec.setPathHashMode(mode)) }

    /// The board's sensor settings ("gps" "1", "gps_interval" "300", …): whatever this board has.
    public func customVars() async throws -> [(name: String, value: String)] {
        guard case .customVars(let v) = try await single(Codec.getCustomVars(), { if case .customVars = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return v
    }
    public func setCustomVar(_ name: String, _ value: String) async throws { try await expectOK(Codec.setCustomVar(name, value)) }

    /// The flood region the radio uses by default (nil: none).
    public func floodScope() async throws -> FloodScope? {
        guard case .floodScope(let s) = try await single(Codec.getFloodScope(), { if case .floodScope = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return s
    }
    public func setFloodScope(_ s: FloodScope?) async throws { try await expectOK(Codec.setFloodScope(s)) }

    /// Erases the radio: identity, contacts, channels, settings (WiFi too). It drops the link before it
    /// can answer, so silence is success.
    public func factoryReset() async throws { try await transport.send(Codec.factoryReset()) }

    /// Runs a command on the radio's own command line (firmware v14+) and returns its answer.
    public func runCommand(_ text: String) async throws -> String {
        guard case .commandReply(let s) = try await single(Codec.runCommand(text), { if case .commandReply = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return s
    }
    public func setTxPower(_ dbm: Int) async throws { try await expectOK(Codec.setTxPower(dbm)) }
    public func setAdvertPosition(_ p: Position) async throws { try await expectOK(Codec.setAdvertPosition(p)) }
    public func setOtherParams(_ o: OtherParams) async throws { try await expectOK(Codec.setOtherParams(o)) }

    public func battery() async throws -> BatteryInfo {
        guard case .battery(let b) = try await single(Codec.getBattery(), { if case .battery = $0 { true } else { false } })
        else { throw RadioError.malformed }
        return b
    }

    /// Restarts the radio (no reply: the connection drops).
    public func reboot() async throws { try await transport.send(Codec.reboot()) }

    /// The Bluetooth pairing PIN: six digits not starting with 0 (0 lets the radio pick a random one).
    public func setDevicePin(_ pin: UInt32) async throws { try await expectOK(Codec.setDevicePin(pin)) }

    // MARK: remote nodes (repeaters, rooms)

    /// Logs in to a repeater or room server (a guest with no password, if it allows that). The answer comes
    /// over the mesh: seconds, or never if the password is wrong.
    public func login(_ key: PublicKey, password: String) async throws -> LoginResult {
        let sent = try await sentInfo(Codec.login(key, password: password))
        let wait = wait(for: sent)
        let prefix = key.prefix(6)
        let result: LoginOutcome = try await waitFor(timeout: wait) { e in
            switch e {
            case .loginSuccess(let r) where r.keyPrefix == prefix: .ok(r)
            case .loginFailed(let p) where p == prefix: .refused
            default: nil
            }
        }
        switch result {
        case .ok(let r): return r
        case .refused: throw RemoteError.loginRefused
        }
    }

    enum LoginOutcome: Sendable { case ok(LoginResult), refused }

    public enum RemoteError: Error, Sendable { case loginRefused }

    /// A node's stats (repeater or room server).
    public func status(_ key: PublicKey) async throws -> NodeStatus {
        let sent = try await sentInfo(Codec.statusRequest(key))
        let prefix = key.prefix(6)
        let data: Data = try await waitFor(timeout: wait(for: sent)) { e in
            if case .statusResponse(let p, let d) = e, p == prefix { return d }
            return nil
        }
        guard let s = NodeStatus(data) else { throw RadioError.malformed }
        return s
    }

    /// A node's readings, as Cayenne LPP bytes (see `Telemetry`). People answer only if their telemetry
    /// settings allow it (no answer otherwise); repeaters and sensors once you're logged in.
    public func telemetry(_ key: PublicKey) async throws -> Data {
        let sent = try await sentInfo(Codec.telemetryRequest(key))
        let prefix = key.prefix(6)
        return try await waitFor(timeout: wait(for: sent)) { e in
            if case .telemetryResponse(let p, let d) = e, p == prefix { return d }
            return nil
        }
    }

    /// A page of the repeaters a repeater hears directly, newest first.
    public func neighbours(_ key: PublicKey, offset: Int = 0) async throws -> (total: Int, list: [Neighbour]) {
        var body = Data([0x06, 0, 255, UInt8(offset & 0xFF), UInt8(offset >> 8), 0, 4])
        body.append(contentsOf: (0..<4).map { _ in UInt8.random(in: 0...255) })
        let sent = try await sentInfo(Codec.binaryRequest(key, body))
        let tag = sent.tag
        let data: Data = try await waitFor(timeout: wait(for: sent)) { e in
            if case .binaryResponse(let t, let d) = e, t == tag { return d }
            return nil
        }
        var r = ByteReader(data)
        let total = Int(Int16(bitPattern: try r.u16())), n = Int(Int16(bitPattern: try r.u16()))
        var list: [Neighbour] = []
        for _ in 0..<max(0, n) {
            guard r.remaining >= 9 else { break }
            list.append(Neighbour(keyPrefix: try r.bytes(4), secondsAgo: Int(try r.i32()), snr: Double(try r.i8()) / 4))
        }
        return (total, list)
    }

    /// Stops keep-alives to a logged-in node (there's no logout message on the air).
    public func logout(_ key: PublicKey) async throws { try await expectOK(Codec.logout(key)) }

    /// Sends a request to a remote node; the radio answers with when it went out and the tag to match.
    // MARK: reach

    /// "Which repeaters hear me?": one zero-hop request; every repeater in earshot answers (after a
    /// random delay, so within a few seconds) with how well it heard you. Repeaters that don't forward,
    /// hide themselves or answered 4 requests in the last 2 minutes stay quiet.
    public func discoverRepeaters(window: Duration = .seconds(5)) async throws -> [DiscoveryAnswer] {
        let tag = UInt32.random(in: 1...UInt32.max)
        async let answers = gather(for: window) { e -> DiscoveryAnswer? in
            if case .controlData(let c) = e { return c.discoveryAnswer(tag: tag) }
            return nil
        }
        try await expectOK(Codec.discoverRepeaters(tag: tag))
        // one answer per node, the best heard
        var best: [Data: DiscoveryAnswer] = [:]
        for a in await answers where a.nodeType == .repeater {
            if best[a.keyPrefix].map({ $0.snrHere < a.snrHere }) ?? true { best[a.keyPrefix] = a }
        }
        return Array(best.values)
    }

    /// A one-hop trace to a repeater: how well it hears you, and you it. It matches on 4 bytes of its
    /// key, so repeaters sharing a short ID don't confuse it.
    public func ping(_ key: PublicKey) async throws -> (up: Double, down: Double) {
        let tag = UInt32.random(in: 1...UInt32.max)
        let sent = try await sentInfo(Codec.trace(tag: tag, flags: 2, path: key.prefix(4)))
        let wait = max(Duration.seconds(3), .milliseconds(Int(sent.timeoutMs) * 5 / 4))
        let result: TraceResult = try await waitFor(timeout: wait) { e in
            if case .traceData(let t) = e, t.tag == tag { return t }
            return nil
        }
        return (result.snrs.first ?? result.finalSNR, result.finalSNR)
    }

    func sentInfo(_ frame: Data) async throws -> SentInfo {
        guard case .sent(let s) = try await single(frame, { if case .sent = $0 { true } else { false } }) else { throw RadioError.malformed }
        return s
    }

    /// How long to wait for an answer over the mesh: the radio's estimate, with margin.
    func wait(for s: SentInfo) -> Duration {
        min(.seconds(45), max(minimumRemoteWait, .milliseconds(Int(s.timeoutMs) * 5 / 4)))
    }
}

/// A repeater's or room server's stats.
public struct NodeStatus: Hashable, Sendable {
    public let batteryMillivolts: Int
    public let txQueue: Int
    public let noiseFloor: Int
    public let lastRSSI: Int
    public let packetsReceived: Int
    public let packetsSent: Int
    public let airtimeSeconds: Int
    public let uptimeSeconds: Int
    public let sentFlood: Int, sentDirect: Int, receivedFlood: Int, receivedDirect: Int
    public let errors: Int
    public let lastSNR: Double
    public let directDuplicates: Int, floodDuplicates: Int
    /// bytes 48–51: a room server's post counts, or a repeater's RX airtime
    public let extra: Data
    /// the stats as received (to keep, and to read again later)
    public let rawBytes: Data

    /// Room servers: posts stored since it started, and pushes of posts to members.
    public var roomPosts: (posted: Int, pushes: Int)? {
        guard extra.count >= 4 else { return nil }
        let e = Data(extra)
        return (Int(e[0]) | Int(e[1]) << 8, Int(e[2]) | Int(e[3]) << 8)
    }

    public init?(_ d: Data) {
        rawBytes = Data(d)
        var r = ByteReader(d)
        guard d.count >= 48,
              let bat = try? r.u16(), let q = try? r.u16(), let nf = try? r.u16(), let rssi = try? r.u16(),
              let rx = try? r.u32(), let tx = try? r.u32(), let air = try? r.u32(), let up = try? r.u32(),
              let sf = try? r.u32(), let sd = try? r.u32(), let rf = try? r.u32(), let rd = try? r.u32(),
              let err = try? r.u16(), let snr = try? r.u16(), let dd = try? r.u16(), let fd = try? r.u16() else { return nil }
        batteryMillivolts = Int(bat); txQueue = Int(q); noiseFloor = Int(Int16(bitPattern: nf)); lastRSSI = Int(Int16(bitPattern: rssi))
        packetsReceived = Int(rx); packetsSent = Int(tx); airtimeSeconds = Int(air); uptimeSeconds = Int(up)
        sentFlood = Int(sf); sentDirect = Int(sd); receivedFlood = Int(rf); receivedDirect = Int(rd)
        errors = Int(err); lastSNR = Double(Int16(bitPattern: snr)) / 4; directDuplicates = Int(dd); floodDuplicates = Int(fd)
        extra = r.rest()
    }
}

public struct Neighbour: Hashable, Sendable {
    public let keyPrefix: Data
    public let secondsAgo: Int
    public let snr: Double
}

/// A thread-safe flag for classify closures.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
