import Foundation
import MeshCoreKit

/// The app's logic, the same as the web app built into MeshChat firmware (`firmware/` in this repo): it keeps
/// the history, sends with retries, links each message to the packets it came in, follows routes, and
/// talks to repeaters and room servers. One radio at a time.
public actor MeshEngine {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    /// What changed, for the UI to refresh.
    public enum Update: Sendable {
        case connection(ConnectionState)
        case radio
        case contacts
        case channels
        case messages(ConversationID)
        /// a new message from someone (for notifications)
        /// backlog: fetched from the radio's queue on connecting (it waited while the app was away)
        case incoming(Message, backlog: Bool)
        case packets
        case rooms
        case routes
        case live(PublicKey)
        /// a command sent to a repeater, its progress, or the repeater's answer
        case console(PublicKey)
        /// the radio heard a new node but its contact list is full (and it doesn't make room)
        case contactsFull
    }

    public enum EngineError: Error, Sendable, CustomStringConvertible {
        case notConnected, cannotSendHere, noFreeChannelSlot, unknownContact, tooLong, badPin
        public var description: String {
            switch self {
            case .notConnected: String(localized: "Not connected to a radio.")
            case .cannotSendHere: String(localized: "You're listening to this channel without joining it, so you can't send there.")
            case .noFreeChannelSlot: String(localized: "All of the radio's channel slots are in use. Leave one first.")
            case .unknownContact: String(localized: "That isn't one of the radio's contacts.")
            case .tooLong: String(localized: "That's longer than a message can be.")
            case .badPin: String(localized: "A PIN is six digits and can't start with 0.")
            }
        }
    }

    public nonisolated let store: Store
    public nonisolated let updates: AsyncStream<Update>
    private let sink: AsyncStream<Update>.Continuation

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var me: SelfInfo?
    public private(set) var device: DeviceInfo?
    public private(set) var contacts: [PublicKey: Contact] = [:]
    public private(set) var channels: [ChannelInfo] = []
    private var client: MeshCoreClient?
    private var eventsTask: Task<Void, Never>?
    /// Which connect is current. Connecting again, or disconnecting, leaves an older attempt still under
    /// way to give up quietly: it mustn't mark the new link failed, or drop it, when it finally fails.
    private var attempt = 0
    /// the radio being connected to, until it's up
    private var connecting: MeshCoreClient?
    private var listenedKeys: [String: Data] = [:]

    /// How long to wait between channel resends (× the attempt number), and at least how long for a DM's
    /// ACK. Shorter in tests.
    public struct Timing: Sendable {
        public var channelRetry: Duration = .seconds(8)
        public var minimumAckWait: Duration = .seconds(8)
        public init() {}
    }
    let timing: Timing

    public init(store: Store, timing: Timing = Timing()) {
        self.store = store
        self.timing = timing
        (updates, sink) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .bufferingNewest(500))
        listenedKeys = Dictionary(((try? store.listened()) ?? []).map { ($0.name, ChannelCrypto.hashtagKey($0.name)) }, uniquingKeysWith: { a, _ in a })
    }

    private func publish(_ u: Update) { sink.yield(u) }
    private func setState(_ s: ConnectionState) { state = s; publish(.connection(s)) }

    /// The radio settings, as a key: messages, packets and heard nodes are kept with the network.
    public var network: String? { me.map { NetworkKey($0.radio).key } }

    /// The protocol's limit for a message, in bytes, for this conversation (channel messages carry "Name: ").
    public func textLimit(for c: ConversationID) -> Int {
        if case .channel = c { return 150 - (me?.name.utf8.count ?? 0) - 2 }
        return 150
    }

    /// What's known about the radio, read in one go.
    public struct Snapshot: Sendable {
        public let me: SelfInfo?
        public let device: DeviceInfo?
        public let channels: [ChannelInfo]
        public let contacts: [PublicKey: Contact]
    }

    public var snapshot: Snapshot { Snapshot(me: me, device: device, channels: channels, contacts: contacts) }

    // MARK: connection

    public func connect(_ transport: MeshTransport) async {
        disconnect()
        attempt += 1
        let mine = attempt
        setState(.connecting(transport.label))
        let c = MeshCoreClient(transport: transport, minimumRemoteWait: timing.minimumAckWait)
        connecting = c
        do {
            let (d, s) = try await c.start(appName: "MeshChat iOS")
            guard mine == attempt else { await c.stop(); return }
            client = c; device = d; me = s
            eventsTask = Task { [weak self] in
                for await e in c.events { await self?.handle(e) }
            }
            try await syncClock(c)
            try await reloadContacts()
            channels = try await c.channels()
            guard mine == attempt else { return }   // (disconnect stopped it)
            connecting = nil
            setState(.connected(transport.label))
            publish(.radio); publish(.channels)
            inBacklog = true
            await drainQueue()
            inBacklog = false
        } catch {
            await c.stop()
            guard mine == attempt else { return }
            connecting = nil
            client = nil
            setState(.failed("\(error)"))
        }
    }

    /// Drops the link, and stops an attempt still under way (it gives up without a word).
    public func disconnect() {
        attempt += 1
        if let c = connecting { Task { await c.stop() } }
        connecting = nil
        eventsTask?.cancel(); eventsTask = nil
        if let c = client { Task { await c.stop() } }
        client = nil
        if state != .disconnected { setState(.disconnected) }
    }

    /// The board has no clock that survives a power cut: set it from the phone when it's behind.
    private func syncClock(_ c: MeshCoreClient) async throws {
        let now = UInt32(Date().timeIntervalSince1970)
        if let t = try? await c.time(), t + 5 < now { try await c.setTime(now) }
    }

    private func connected() throws -> MeshCoreClient {
        guard let client else { throw EngineError.notConnected }
        return client
    }

    // MARK: radio events

    private func handle(_ e: MeshEvent) async {
        switch e {
        case .rxLog(let entry): await recordPacket(entry)
        case .messagesWaiting: await drainQueue()
        case .messageForAnotherApp(let m): await record(m)
        case .sendConfirmed(let ack, let rtt): ackArrived(ack, roundTripMs: rtt)
        case .pathUpdated(let key): await routeLearned(key)
        case .advert(let key): await refreshContact(key)
        case .contactDeleted(let key): contacts[key] = nil; publish(.contacts)
        case .contactsFull: publish(.contactsFull)
        case .disconnected(let why):
            client = nil
            setState(why.map { .failed($0) } ?? .disconnected)
        default: break
        }
    }

    private var draining = false, drainAgain = false
    /// draining what queued up while the app was away
    private var inBacklog = false

    /// Takes everything waiting in the radio's queue.
    private func drainQueue() async {
        if draining { drainAgain = true; return }
        draining = true
        defer { draining = false }
        repeat {
            drainAgain = false
            while let c = client, let m = try? await c.nextMessage() { await record(m) }
        } while drainAgain
    }

    // MARK: contacts and channels

    private var contactsLastModified: UInt32 = 0

    public func reloadContacts() async throws {
        let (list, last) = try await connected().contacts()
        contacts = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        contactsLastModified = last
        publish(.contacts)
    }

    private func refreshContact(_ key: PublicKey) async {
        guard let c = try? await client?.contact(key) else { return }
        contacts[key] = c
        publish(.contacts)
    }

    public func contact(prefix: Data) -> Contact? {
        contacts.values.first { $0.key.bytes.starts(with: prefix) }
    }

    /// Adds a contact from a QR code or link. One that already exists is left as it is (re-adding would
    /// forget its learned route).
    @discardableResult
    public func addContact(key: PublicKey, name: String, type: NodeType) async throws -> Bool {
        if contacts[key] != nil { return false }
        try await connected().addOrUpdate(Contact(key: key, type: type, name: name))
        await refreshContact(key)
        return true
    }

    public func removeContact(_ key: PublicKey) async throws {
        try await connected().remove(key)
        contacts[key] = nil
        publish(.contacts)
    }

    /// Removes these contacts in turn (the radio has no command for several), as ordered; `progress` gets
    /// how many are done. One the radio no longer has counts as done. Stops when the task is cancelled, and
    /// throws when the link drops (what was removed by then stays removed). Returns how many were done.
    @discardableResult
    public func removeContacts(_ keys: [PublicKey], progress: @Sendable (Int) async -> Void = { _ in }) async throws -> Int {
        let c = try connected()
        var done = 0
        defer { publish(.contacts) }
        for key in keys {
            if Task.isCancelled { break }
            do { try await c.remove(key) } catch RadioError.notFound {}
            contacts[key] = nil
            done += 1
            if done % 10 == 0 { publish(.contacts) }
            await progress(done)
        }
        return done
    }

    /// Star the contacts you use (people you message, rooms you join, repeaters you log in to as admin), so
    /// the radio never drops them to make room for new nodes. The app turns it on unless you turn it off.
    public private(set) var starWhatYouUse = false
    public func setStarWhatYouUse(_ on: Bool) { starWhatYouUse = on }

    /// Stars it, if that's on and it isn't one already (in the background: a message isn't held up).
    private func starIfUsed(_ key: PublicKey) {
        guard starWhatYouUse, let c = contacts[key], !c.isFavourite else { return }
        Task { try? await self.setFavourite(key, true) }
    }

    /// Marks a contact a favourite, or not. The radio never removes a favourite to make room for new nodes.
    public func setFavourite(_ key: PublicKey, _ on: Bool) async throws {
        let client = try connected()
        // the radio's own record, so the update carries its route and advert as they are now
        guard var c = try await client.contact(key) else { throw EngineError.unknownContact }
        c.flags = on ? c.flags | 0x01 : c.flags & ~0x01
        // kept as it was: a star isn't hearing it
        try await client.addOrUpdate(c, lastModified: c.lastModified > 0 ? c.lastModified : nil)
        await refreshContact(key)
    }

    /// Joins a channel in the first free slot: a hashtag channel by name, or a private one with its key.
    public func joinChannel(name: String, secret: Data? = nil) async throws -> ChannelInfo {
        let c = try connected()
        let used = Set(channels.map(\.index))
        guard let slot = (0..<(device?.maxChannels ?? 8)).first(where: { !used.contains($0) }) else { throw EngineError.noFreeChannelSlot }
        let key = secret ?? ChannelCrypto.hashtagKey(name)
        try await c.setChannel(slot, name: name, secret: key)
        channels = try await c.channels()
        publish(.channels)
        return ChannelInfo(index: slot, name: name, secret: key)
    }

    public func leaveChannel(_ index: Int) async throws {
        let c = try connected()
        try await c.setChannel(index, name: "", secret: Data(count: 16))
        channels = try await c.channels()
        publish(.channels)
    }

    /// Reads a hashtag channel without joining it (no slot used; you can't send there).
    public func listen(to name: String) throws {
        let n = name.hasPrefix("#") ? name.lowercased() : "#" + name.lowercased()
        try store.save(ListenedChannel(name: n, added: .now))
        listenedKeys[n] = ChannelCrypto.hashtagKey(n)
        publish(.channels)
    }

    public func stopListening(to name: String) throws {
        try store.removeListened(name)
        listenedKeys[name] = nil
        publish(.channels)
    }

    // MARK: incoming messages

    /// Channel packets heard lately, decrypted: to give a message from the queue its route and signal.
    private struct HeardChannelPacket {
        let channel: Int, timestamp: UInt32, text: String
        let packet: PacketRecord
    }
    private var recentChannelPackets: [HeardChannelPacket] = []

    private func record(_ received: ReceivedMessage) async {
        switch received {
        case .channel(let m):
            let conv = ConversationID.channel(m.channelIndex)
            let (sender, body) = m.parts
            if (try? store.hasIncoming(conv, senderTimestamp: m.senderTimestamp, text: body)) == true { return }
            var msg = Message(senderTimestamp: m.senderTimestamp, conversation: conv, direction: .incoming, sender: sender, text: body,
                              status: .received, hops: m.floodHops, hashSize: m.pathHashSize, snr: m.snr, network: network)
            if let heard = recentChannelPackets.last(where: { $0.channel == m.channelIndex && $0.timestamp == m.senderTimestamp && $0.text == m.text }) {
                link(&msg, to: heard.packet)
            }
            insertIncoming(msg)
        case .contact(let m):
            if m.textType == .cliData {   // a command's answer, not chat
                if let from = contact(prefix: m.senderPrefix) { appendConsole(from.key, isCommand: false, status: .received, text: m.text) }
                return
            }
            let from = contact(prefix: m.senderPrefix)
            let key = from?.key ?? PublicKey(m.senderPrefix + Data(count: 26))!
            let conv = ConversationID.direct(key)
            var sender = from?.name ?? m.senderPrefix.prefix(4).hex
            if let author = m.authorPrefix {   // a room post: signed by its author
                if (try? store.room(key.hex))?.left == true { return }   // a room you left keeps pushing posts
                sender = contact(prefix: author)?.name ?? (key.bytes.starts(with: author) ? (from?.name ?? "room") : author.hex)
            }
            if (try? store.hasIncoming(conv, senderTimestamp: m.senderTimestamp, text: m.text)) == true { return }
            var msg = Message(senderTimestamp: m.senderTimestamp, conversation: conv, direction: .incoming, sender: sender, text: m.text,
                              status: .received, hops: m.floodHops ?? 0, hashSize: m.pathHashSize, snr: m.snr)
            msg.author = m.authorPrefix?.hex
            // which packet? a TXT_MSG to us from that sender, in the last 30 s, with the same hop count
            if let mine = me?.key.prefix(1), let p = (try? store.recentPackets(type: "TXT_MSG", since: .now - 30))?.first(where: { p in
                p.raw.count > 0 && MeshPacket(raw: p.raw).map { pk in
                    pk.payload.count >= 4 && pk.payload.prefix(1) == mine && pk.payload.dropFirst().prefix(1) == key.prefix(1)
                    && (m.floodHops == nil || pk.hops == m.floodHops)
                } == true && (try? store.isFingerprintLinked(p.fingerprint)) != true
            }) {
                link(&msg, to: p)
            }
            insertIncoming(msg)
        }
    }

    private func link(_ m: inout Message, to p: PacketRecord) {
        m.fingerprint = p.fingerprint
        m.path = p.path.isEmpty ? nil : p.path
        m.hops = p.hops
        m.hashSize = p.hashSize
        if m.snr == nil || p.hops > 0 { m.snr = p.snr }
        m.rssi = p.rssi
    }

    private func insertIncoming(_ m: Message) {
        guard let saved = try? store.insert(m) else { return }
        publish(.messages(saved.conversation))
        publish(.incoming(saved, backlog: inBacklog))
    }

    // MARK: the packet log

    private var lastPathPacket: PacketRecord?

    private func recordPacket(_ e: RxLogEntry) async {
        guard let p = e.packet else { return }
        var rec = PacketRecord(date: .now, route: "\(p.route)", type: p.payloadType.name, hops: p.hops, path: p.path.map(\.hex).joined(),
                               hashSize: p.hashSize, snr: e.snr, rssi: e.rssi, fingerprint: Int64(p.fingerprint), raw: e.raw,
                               channelHash: p.payloadType == .groupText ? p.payload.first.map(Int.init) : nil, network: network)
        guard let saved = try? store.insert(rec) else { return }
        rec = saved
        switch p.payloadType {
        case .advert: if let a = p.advert { recordAdvert(a, rec) }
        case .groupText: groupText(p, rec)
        case .textMessage: ownDMEcho(p, rec)
        case .path: lastPathPacket = rec
        default: break
        }
        publish(.packets)
    }

    private func recordAdvert(_ a: Advert, _ p: PacketRecord) {
        // a record per network: what it's like there (hops, signal, how often) is that network's
        let net = network ?? ""
        var h = (try? store.heardNode(a.key.hex, network: net))
            ?? HeardNode(key: a.key.hex, name: a.name, type: Int(a.type.rawValue), firstHeard: p.date, lastHeard: p.date, snr: p.snr,
                         rssi: p.rssi, hops: p.hops, path: p.path, hashSize: p.hashSize, count: 0, network: net)
        if !a.name.isEmpty { h.name = a.name }
        h.type = Int(a.type.rawValue)
        if let pos = a.position { h.latitude = pos.latitude; h.longitude = pos.longitude }
        h.lastHeard = p.date; h.snr = p.snr; h.rssi = p.rssi; h.hops = p.hops; h.path = p.path; h.hashSize = p.hashSize
        h.count += 1
        try? store.save(h)
    }

    /// A channel packet: one of ours coming back from a repeater, a message for a joined channel (kept
    /// to link with the queue), or one for a channel we're listening to.
    private func groupText(_ p: MeshPacket, _ rec: PacketRecord) {
        guard let id = p.payload.first else { return }
        for ch in channels where ch.hash == id {
            guard let plain = ChannelCrypto.decryptGroupText(p.payload, key: ch.secret) else { continue }
            if let me, plain.text.hasPrefix(me.name + ": "),
               var mine = try? store.outgoing(.channel(ch.index), since: .now - 600).first(where: {
                   $0.senderTimestamp == plain.timestamp && me.name + ": " + $0.text == plain.text }) {
                mine.repeats += 1
                if mine.status != .repeated { mine.status = .repeated; link(&mine, to: rec) }
                try? store.update(mine)
                publish(.messages(mine.conversation))
            } else {
                recentChannelPackets.append(HeardChannelPacket(channel: ch.index, timestamp: plain.timestamp, text: plain.text, packet: rec))
                if recentChannelPackets.count > 64 { recentChannelPackets.removeFirst(16) }
            }
            return
        }
        for (name, key) in listenedKeys where ChannelCrypto.hash(of: key) == id {
            guard let plain = ChannelCrypto.decryptGroupText(p.payload, key: key) else { continue }
            if (try? store.isFingerprintLinked(rec.fingerprint)) == true { return }   // another copy of one we have
            let conv = ConversationID.listened(name)
            let parts = ChannelMessage.split(plain.text)
            var m = Message(senderTimestamp: plain.timestamp, conversation: conv, direction: .incoming, sender: parts.sender, text: parts.body,
                            status: .received, network: network)
            link(&m, to: rec)
            insertIncoming(m)
            return
        }
    }

    /// One of our DMs passed on by a repeater: gives it its fingerprint (for Details).
    private func ownDMEcho(_ p: MeshPacket, _ rec: PacketRecord) {
        guard let mine = me?.key.prefix(1), p.payload.count >= 4, p.payload.dropFirst().prefix(1) == mine,
              let to = p.payload.first else { return }
        guard var m = try? store.outgoing(since: .now - 120).first(where: {
            if case .direct(let k) = $0.conversation { return k.bytes.first == to && $0.fingerprint == nil }
            return false
        }) else { return }
        m.fingerprint = rec.fingerprint
        try? store.update(m)
    }

    // MARK: sending

    /// Sends a message. Channel messages are sent again (the same packet) until a repeater is heard
    /// passing one on, up to three times. DMs go on the saved route twice, then the route is forgotten and
    /// the last try floods; each try's way and the ACK's round trip are kept.
    @discardableResult
    public func send(_ text: String, to conv: ConversationID) async throws -> Message {
        let c = try connected()
        guard let me else { throw EngineError.notConnected }
        guard text.utf8.count <= textLimit(for: conv) else { throw EngineError.tooLong }
        let ts = UInt32(Date().timeIntervalSince1970)
        switch conv {
        case .listened:
            throw EngineError.cannotSendHere
        case .channel(let slot):
            var m = try store.insert(Message(senderTimestamp: ts, conversation: conv, direction: .outgoing, sender: me.name, text: text,
                                             status: .sending, network: network))
            do {
                try await c.sendChannelText(channel: slot, text: text, timestamp: ts)
                m.status = .sent
            } catch { m.status = .failed }
            try store.update(m)
            publish(.messages(conv))
            if m.status == .sent, let id = m.id { Task { await self.channelRetries(id, slot: slot, text: text, timestamp: ts) } }
            return m
        case .direct(let key):
            guard contacts[key] != nil else { throw EngineError.unknownContact }
            let m = try store.insert(Message(senderTimestamp: ts, conversation: conv, direction: .outgoing, sender: me.name, text: text,
                                             status: .sending))
            publish(.messages(conv))
            if let id = m.id { Task { await self.directTries(id, to: key, text: text, timestamp: ts) } }
            starIfUsed(key)
            return m
        }
    }

    /// Resends a channel message no repeater was heard passing on (the same packet: it isn't a duplicate).
    public func resend(_ id: Int64) async throws {
        guard var m = try store.message(id), m.direction == .outgoing, case .channel(let slot) = m.conversation, let ts = m.senderTimestamp else { return }
        try await connected().sendChannelText(channel: slot, text: m.text, timestamp: ts)
        m.status = .sent; m.attempts += 1
        try store.update(m)
        publish(.messages(m.conversation))
        Task { await self.channelRetries(id, slot: slot, text: m.text, timestamp: ts) }
    }

    private func channelRetries(_ id: Int64, slot: Int, text: String, timestamp: UInt32) async {
        while true {
            guard let m = try? store.message(id) else { return }
            try? await Task.sleep(for: timing.channelRetry * m.attempts)
            guard var now = try? store.message(id), now.status == .sent else { return }   // a repeater passed it on
            if now.attempts >= 3 {
                now.status = .notHeard
                try? store.update(now); publish(.messages(now.conversation)); return
            }
            guard let c = client, (try? await c.sendChannelText(channel: slot, text: text, timestamp: timestamp)) != nil else { return }
            now.attempts += 1
            try? store.update(now); publish(.messages(now.conversation))
        }
    }

    // ACK codes of our DMs' tries → (message, try number)
    private var expectedAcks: [UInt32: (id: Int64, attempt: Int)] = [:]
    private var ackWaiters: [Int64: CheckedContinuation<Void, Never>] = [:]

    private func directTries(_ id: Int64, to key: PublicKey, text: String, timestamp: UInt32) async {
        var tries: [Bool] = []
        for attempt in 0..<3 {
            guard let c = client, var m = try? store.message(id), m.status == .sending else { return }
            if attempt == 2, contacts[key]?.outPath != nil {   // the last try floods: forget the route first
                routeWillReset(key, by: "retry")
                try? await c.resetPath(key)
                await refreshContact(key)
            }
            guard let sent = try? await c.sendText(to: key, text: text, timestamp: timestamp, attempt: attempt) else {
                if attempt == 0 { m.status = .failed; try? store.update(m); publish(.messages(m.conversation)) }
                return
            }
            tries.append(sent.flood)
            expectedAcks[sent.tag] = (id, attempt + 1)
            m.attempts = attempt + 1; m.triesFlood = tries
            try? store.update(m); publish(.messages(m.conversation))
            if await waitForAck(id, timeout: max(timing.minimumAckWait, .milliseconds(Int(sent.timeoutMs) * 6 / 5))) { return }
        }
        if var m = try? store.message(id), m.status == .sending {
            m.status = .noAck
            try? store.update(m); publish(.messages(m.conversation))
        }
    }

    private func ackArrived(_ ack: UInt32, roundTripMs: UInt32) {
        guard let (id, attempt) = expectedAcks.removeValue(forKey: ack), var m = try? store.message(id), m.status != .delivered else { return }
        m.status = .delivered; m.ackTry = attempt; m.roundTripMs = Int(roundTripMs)
        try? store.update(m)
        publish(.messages(m.conversation))
        ackWaiters.removeValue(forKey: id)?.resume()
    }

    private func waitForAck(_ id: Int64, timeout: Duration) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ackWaiters[id] = c
            Task {
                try? await Task.sleep(for: timeout)
                self.ackWaiters.removeValue(forKey: id)?.resume()
            }
        }
        return (try? store.message(id))?.status == .delivered
    }

    // MARK: routes

    /// Forgets the saved route to a contact: the next message floods and learns a fresh one.
    public func resetPath(_ key: PublicKey) async throws {
        routeWillReset(key, by: "you")
        try await connected().resetPath(key)
        await refreshContact(key)
    }

    private func routeWillReset(_ key: PublicKey, by: String) {
        guard let path = contacts[key]?.outPath else { return }
        var h = (try? store.route(key.hex)) ?? RouteHistory(key: key.hex)
        let cur = StoredPath(path)
        h.previousSince = h.current == cur ? h.learned : nil
        h.previous = cur
        h.current = nil; h.learned = nil; h.viaPacket = nil
        h.reset = .now; h.resetBy = by
        try? store.save(h)
        publish(.routes)
    }

    /// The radio stored a route (a PATH packet answered a flood): when, what it replaced, and how it came.
    private func routeLearned(_ key: PublicKey) async {
        await refreshContact(key)
        guard let path = contacts[key]?.outPath else { return }
        var h = (try? store.route(key.hex)) ?? RouteHistory(key: key.hex)
        let cur = StoredPath(path)
        if h.current == cur {
            if h.learned == nil { h.learned = .now }
            h.confirmed = .now
        } else {
            if let c = h.current { h.previous = c; h.previousSince = h.learned }
            if let p = h.previous, p != cur { h.changes += 1 }
            h.current = cur; h.learned = .now; h.confirmed = .now
        }
        h.learns += 1
        if let p = lastPathPacket, Date().timeIntervalSince(p.date) < 3 {
            h.viaPacket = p.id; h.viaSNR = p.snr; h.viaRSSI = p.rssi; h.viaHops = p.hops
        } else {
            h.viaPacket = nil
        }
        try? store.save(h)
        publish(.routes)
    }

    // MARK: repeaters and rooms

    private static let roles = ["guest", "read-only", "read-write", "admin"]

    /// Logs in (a guest unless a password is given), asks for status, and for a repeater the repeaters it
    /// hears; then logs out again (rooms: stays, that's joining). The answer is kept.
    @discardableResult
    public func query(_ key: PublicKey, password: String = "") async throws -> LiveAnswer {
        let c = try connected()
        let isRoom = contacts[key]?.type == .room
        var answer = LiveAnswer(key: key.hex, date: .now, ok: false, admin: false)
        flooded.remove(key)
        defer { flooded.remove(key) }
        do {
            let login = try await ask(key, c) { try await c.login(key, password: password) }
            answer.ok = true
            answer.admin = login.permissions == 1
            answer.role = login.aclRole.map { Self.roles[Int($0)] }
            answer.serverTime = login.serverTime
            answer.firmwareLevel = login.firmwareLevel.map(Int.init)
            // a room just joined is busy pushing posts and answers late: no flood for its status
            if let s = try? await (isRoom ? c.status(key) : ask(key, c) { try await c.status(key) }) { answer.status = s.rawBytes }
            if !isRoom {
                var all: [Neighbour] = [], total = 0
                for _ in 0..<4 {
                    let offset = all.count
                    guard let page = try? await ask(key, c, { try await c.neighbours(key, offset: offset) }) else { break }
                    total = page.total; all += page.list
                    if page.list.isEmpty || all.count >= total { break }
                }
                answer.neighbours = all.map { StoredNeighbour(prefix: $0.keyPrefix.hex, secondsAgo: $0.secondsAgo, snr: $0.snr) }
                answer.neighboursTotal = total
                try? await c.logout(key)
            }
        } catch MeshCoreClient.RemoteError.loginRefused {
            answer.error = isRoom ? String(localized: "Login refused by the room.") : String(localized: "Login refused: it needs a password (or a different one).")
        } catch RadioError.timeout {
            answer.error = String(localized: "No answer, on the saved route or by flood. It may need a password (a wrong one gets no reply), or the request or its answer was lost on the way.")
        }
        try store.save(answer)
        if answer.ok && (isRoom || answer.admin) { starIfUsed(key) }
        if isRoom && answer.ok {
            let prev = try store.room(key.hex)
            try store.save(RoomMembership(key: key.hex, joined: prev?.left == false ? prev?.joined : .now, loginAt: .now, left: false,
                                          leftAt: nil, role: answer.role, admin: answer.admin))
            publish(.rooms)
        }
        publish(.live(key))
        return answer
    }

    /// Asks a node for its readings (battery, temperature, position, its sensors): people directly (they
    /// answer only if their settings let you), repeaters and sensors after logging in as a guest, then out
    /// again. Rooms aren't asked: logging in to a room joins it. The answer, or why there's none, is kept.
    @discardableResult
    public func telemetry(_ key: PublicKey) async throws -> TelemetryAnswer {
        let c = try connected()
        guard let contact = contacts[key], contact.type != .room else { throw EngineError.unknownContact }
        var answer = TelemetryAnswer(key: key.hex, date: .now)
        flooded.remove(key)
        defer { flooded.remove(key) }
        let loginFirst = contact.type == .repeater || contact.type == .sensor
        var loggedIn = false
        do {
            if loginFirst {
                _ = try await ask(key, c) { try await c.login(key, password: "") }
                loggedIn = true
            }
            answer.data = try await ask(key, c) { try await c.telemetry(key) }
        } catch MeshCoreClient.RemoteError.loginRefused {
            answer.error = String(localized: "It doesn't let guests in, so it shares readings only with a password (its admin page).")
        } catch RadioError.timeout {
            answer.error = contact.type == .companion
                ? String(localized: "No answer. They may not share readings (each person chooses who may, in their app), or the request or answer was lost on the way.")
                : String(localized: "No answer, on the saved route or by flood: the request or its answer was lost on the way.")
        }
        if loggedIn { try? await c.logout(key) }
        answer.date = .now
        try store.save(answer)
        publish(.live(key))
        return answer
    }

    // MARK: admin commands

    /// Each repeater's (or room server's) command line: commands sent from here and its answers, this
    /// session only. Passwords in them are masked (see AdminConsole).
    public private(set) var consoles: [PublicKey: [ConsoleLine]] = [:]
    private var nextConsoleID = 1

    /// Runs a command on a repeater or room server: needs an admin login (see `query`), or it's ignored.
    public func runCommand(_ text: String, on key: PublicKey) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return }
        let id = appendConsole(key, isCommand: true, status: .sending, text: t)
        do {
            guard contacts[key] != nil else { throw EngineError.unknownContact }
            _ = try await connected().sendCommand(to: key, String(t.prefix(150)))
            setConsoleStatus(key, id, .sent)
        } catch {
            setConsoleStatus(key, id, .failed)
        }
    }

    @discardableResult
    private func appendConsole(_ key: PublicKey, isCommand: Bool, status: ConsoleLine.Status, text: String) -> Int {
        let id = nextConsoleID
        nextConsoleID += 1
        var lines = consoles[key] ?? []
        lines.append(ConsoleLine(id: id, isCommand: isCommand, status: status, text: text))
        consoles[key] = Array(lines.suffix(60))
        publish(.console(key))
        return id
    }

    private func setConsoleStatus(_ key: PublicKey, _ id: Int, _ status: ConsoleLine.Status) {
        guard let i = consoles[key]?.firstIndex(where: { $0.id == id }) else { return }
        consoles[key]?[i].status = status
        publish(.console(key))
    }

    /// Repeaters and rooms whose query has already forgotten the saved route and flooded.
    private var flooded: Set<PublicKey> = []

    /// One request in a query. No answer on the saved route: it may work one way only (the answer comes
    /// back through repeaters that don't hear each other well), or a repeater on it is gone. Forget it
    /// and ask again by flood, once per query, as a DM's last try does; the answer brings a fresh route.
    private func ask<T: Sendable>(_ key: PublicKey, _ c: MeshCoreClient, _ request: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch RadioError.timeout where !flooded.contains(key) && contacts[key]?.outPath != nil {
            flooded.insert(key)
            routeWillReset(key, by: "retry")
            try await c.resetPath(key)
            await refreshContact(key)
            return try await request()
        }
    }

    /// Stops showing a room's posts. MeshCore has no "leave" message: the room keeps pushing new posts
    /// while the radio acknowledges them, so they're dropped here.
    public func leaveRoom(_ key: PublicKey) async throws {
        var r = try store.room(key.hex) ?? RoomMembership(key: key.hex, left: false, admin: false)
        r.left = true; r.leftAt = .now
        try store.save(r)
        try? await client?.logout(key)
        publish(.rooms)
    }

    // MARK: deleting (from this device's history only: the other side keeps theirs)

    public func deleteMessage(_ id: Int64) throws {
        guard let m = try store.message(id) else { return }
        try store.deleteMessage(id)
        publish(.messages(m.conversation))
    }

    @discardableResult
    public func deleteConversation(_ c: ConversationID) throws -> Int {
        let n = try store.deleteConversation(c)
        publish(.messages(c))
        return n
    }

    // MARK: reach

    /// Which repeaters hear you right now (one zero-hop request; answers within 5 s).
    public func checkReach() async throws -> [DiscoveryAnswer] { try await connected().discoverRepeaters() }

    /// How well one repeater and you hear each other (a one-hop trace).
    public func ping(_ key: PublicKey) async throws -> (up: Double, down: Double) { try await connected().ping(key) }

    // MARK: your node

    public func sendAdvert(flood: Bool) async throws { try await connected().sendAdvert(flood: flood) }

    /// Whether adverts carry a position, and which: `position` nil keeps the one the radio has.
    public func setLocation(shared: Bool, position: Position?) async throws {
        let c = try connected()
        if let position { try await c.setAdvertPosition(position) }
        if var o = me?.otherParams, o.locationPolicy != (shared ? 1 : 0) {
            o.locationPolicy = shared ? 1 : 0
            try await c.setOtherParams(o)
        }
        me = try await c.appStart(name: "MeshChat iOS")
        publish(.radio)
    }

    public func rename(_ name: String) async throws {
        let c = try connected()
        try await c.setName(name)
        me = try await c.appStart(name: "MeshChat iOS")
        publish(.radio)
    }

    /// Switches network: the radio applies it at once and saves it. Its repeat setting is kept (the
    /// firmware turns repeat off when an app leaves it out), unless the new frequency doesn't allow it.
    public func setRadio(_ s: RadioSettings) async throws {
        let c = try connected()
        try await c.setRadio(s, repeat: await repeatFlag(c, for: s, wanted: device?.repeatEnabled ?? false))
        await reread(c)
    }

    /// Where a profile fails, for saying so.
    public struct ApplyFailure: Error, CustomStringConvertible {
        public let step: String
        public let error: Error
        public var description: String {
            // one whole sentence per step (the steps `apply` names), for translation
            let why = String(describing: error)
            return switch step {
            case "network settings": String(localized: "The network settings didn't take: \(why)")
            case "transmit power": String(localized: "The transmit power didn't take: \(why)")
            case "path hash size": String(localized: "The path hash size didn't take: \(why)")
            default: "The \(step) didn't take: \(why)"
            }
        }
    }

    /// Puts the radio on a saved network: its LoRa settings, then its transmit power and path hash size
    /// if it has them. Stops at the first refusal and says which.
    public func apply(_ p: RadioProfile) async throws {
        let c = try connected()
        do { try await c.setRadio(p.radio, repeat: await repeatFlag(c, for: p.radio, wanted: device?.repeatEnabled ?? false)) }
        catch { await reread(c); throw ApplyFailure(step: "network settings", error: error) }
        if let tx = p.txPower, let me {
            do { try await c.setTxPower(min(tx, me.maxTxPower)) }
            catch { await reread(c); throw ApplyFailure(step: "transmit power", error: error) }
        }
        if let h = p.pathHashMode, (device?.firmwareCode ?? 0) >= 10 {
            do { try await c.setPathHashMode(h) }
            catch { await reread(c); throw ApplyFailure(step: "path hash size", error: error) }
        }
        await reread(c)
    }

    /// The repeat byte to send with radio settings: nil for firmware before v9 (which takes none), and
    /// never on where the radio may not repeat.
    private func repeatFlag(_ c: MeshCoreClient, for s: RadioSettings, wanted: Bool) async -> Bool? {
        guard (device?.firmwareCode ?? 0) >= 9 else { return nil }
        guard wanted else { return false }
        let allowed = (try? await c.repeatFrequencies()) ?? []
        return allowed.contains { $0.contains(mhz: s.frequencyMHz) }
    }

    /// Reads the radio's own settings back after a change, so screens show what it really took.
    private func reread(_ c: MeshCoreClient) async {
        if let m = try? await c.appStart(name: "MeshChat iOS") { me = m }
        if let d = try? await c.deviceQuery() { device = d }
        publish(.radio)
    }

    public func setTxPower(_ dbm: Int) async throws {
        let c = try connected()
        try await c.setTxPower(dbm)
        await reread(c)
    }

    /// Repeating other nodes' packets (firmware v9+), on frequencies where the radio may.
    public func setRepeat(_ on: Bool) async throws {
        let c = try connected()
        guard let me else { throw EngineError.notConnected }
        try await c.setRadio(me.radio, repeat: on)
        await reread(c)
    }

    /// Where the radio may repeat (empty when the firmware doesn't say).
    public func repeatFrequencies() async throws -> [FrequencyRange] { try await connected().repeatFrequencies() }

    /// 0, 1 or 2: path hashes of 1, 2 or 3 bytes (firmware v10+).
    public func setPathHashMode(_ mode: Int) async throws {
        let c = try connected()
        try await c.setPathHashMode(mode)
        await reread(c)
    }

    /// Adding contacts by hand, telemetry, position in adverts, extra acknowledgements: one command.
    public func setOtherParams(_ o: OtherParams) async throws {
        let c = try connected()
        try await c.setOtherParams(o)
        await reread(c)
    }

    public func tuning() async throws -> TuningParams { try await connected().tuning() }
    /// Clamped as the firmware clamps them when it loads (0–20 and 0–9).
    public func setTuning(_ t: TuningParams) async throws {
        try await connected().setTuning(TuningParams(rxDelayBase: min(20, max(0, t.rxDelayBase)), airtimeFactor: min(9, max(0, t.airtimeFactor))))
    }

    public func autoAdd() async throws -> AutoAddConfig { try await connected().autoAdd() }
    public func setAutoAdd(_ a: AutoAddConfig) async throws { try await connected().setAutoAdd(a) }

    public func floodScope() async throws -> FloodScope? { try await connected().floodScope() }
    public func setFloodScope(_ s: FloodScope?) async throws { try await connected().setFloodScope(s) }

    /// The board's sensor settings (GPS and such), as name and value.
    public func customVars() async throws -> [(name: String, value: String)] { try await connected().customVars() }
    public func setCustomVar(_ name: String, _ value: String) async throws { try await connected().setCustomVar(name, value) }

    /// The radio's clock.
    public func radioTime() async throws -> Date { Date(timeIntervalSince1970: Double(try await connected().time())) }
    /// Sets the radio's clock from this device's.
    public func syncClock() async throws { try await connected().setTime(UInt32(Date.now.timeIntervalSince1970)) }

    /// Erases the radio (identity, contacts, channels, settings, its WiFi network too). The link drops at
    /// once; nothing comes back.
    public func factoryReset() async throws { try await connected().factoryReset() }

    public func battery() async throws -> BatteryInfo { try await connected().battery() }

    /// Sets the Bluetooth pairing PIN (paired phones keep working; new ones need it). Rejects a PIN the
    /// radio would refuse before sending it.
    public func setDevicePin(_ pin: String) async throws {
        guard let p = BluetoothPin(pin) else { throw EngineError.badPin }
        try await connected().setDevicePin(p.value)
        if let d = try? await connected().deviceQuery() { device = d }
        publish(.radio)
    }

    /// Restarts the radio: the connection drops, and the app reconnects when it's back.
    public func reboot() async throws { try await connected().reboot() }
}

/// A Bluetooth pairing PIN as MeshCore accepts it: six digits, not starting with 0.
public struct BluetoothPin: Hashable, Sendable {
    public let value: UInt32
    public init?(_ text: String) {
        guard text.count == 6, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), text.first != "0", let v = UInt32(text) else { return nil }
        value = v
    }
}
