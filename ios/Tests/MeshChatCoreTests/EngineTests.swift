import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit
import MeshChatTestSupport

/// The engine against a simulated radio: the same flows the web app's server handles.
@Suite("Engine", .serialized)
struct EngineTests {
    static let publicKey = Data(hex: "8b3387e9c5cdea6ac9e5edbaa115cd72")!
    let alice = Contact(key: PublicKey(Data(repeating: 0xB2, count: 32))!, type: .companion,
                        outPath: OutPath(hashSize: 1, hops: [Data([0x39])]), name: "Alice")
    let room = Contact(key: PublicKey(Data(repeating: 0xC3, count: 32))!, type: .room, name: "LUNA")
    let wenera = Contact(key: PublicKey(Data([0x4A, 0x02, 0xFD, 0xBA]) + Data(repeating: 0xD4, count: 28))!, type: .companion, name: "Wenera")

    func setUp(_ configure: (FakeRadio) -> Void = { _ in }) async throws -> (MeshEngine, FakeRadio) {
        let radio = FakeRadio(contacts: [alice, room, wenera], channels: [ChannelInfo(index: 0, name: "Public", secret: Self.publicKey)])
        configure(radio)
        var timing = MeshEngine.Timing()
        timing.channelRetry = .milliseconds(60)
        timing.minimumAckWait = .milliseconds(150)
        let engine = MeshEngine(store: try .inMemory(), timing: timing)
        await engine.connect(radio)
        return (engine, radio)
    }

    func eventually(_ timeout: Duration = .seconds(3), _ check: @escaping () async throws -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out")
    }

    @Test func connectsAndLoadsTheRadio() async throws {
        let (engine, radio) = try await setUp()
        #expect(await engine.state == .connected("fake radio"))
        #expect(await engine.contacts.count == 3)
        #expect(await engine.channels.map(\.name) == ["Public"])
        #expect(await engine.network == "869.618/62.5/6")
        // the radio's clock was behind: set from this device's
        #expect(radio.commands.contains { $0.first == 6 })
    }

    @Test func aRepeaterHeardOnTwoNetworks() async throws {
        let (engine, radio) = try await setUp()
        let south = "869.618/62.5/6", national = "869.618/62.5/8"
        let rpt = PublicKey(Data(repeating: 0xE5, count: 32))!
        radio.push(radio.rxLog(radio.advertPacket(key: rpt, type: .repeater, name: "Szczyt", path: [0x39])))
        try await eventually { try engine.store.heardNode(rpt.hex, network: south) != nil }
        try await engine.apply(RadioProfile.suggested[1])   // MeshCore Polska: the same frequency, SF8
        #expect(await engine.network == national)
        radio.push(radio.rxLog(radio.advertPacket(key: rpt, type: .repeater, name: "Szczyt")))   // there, heard directly
        try await eventually { try engine.store.heardNode(rpt.hex, network: national) != nil }
        let there = try #require(try engine.store.heardNode(rpt.hex, network: national))
        let before = try #require(try engine.store.heardNode(rpt.hex, network: south))
        #expect(before.hops == 1 && there.hops == 0)   // each network's own
        #expect(before.count == 1 && there.count == 1)
        #expect(try engine.store.recentPackets(since: .now - 60, network: south).count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func switchingAwayFromARadioThatDoesntAnswer() async throws {
        let engine = MeshEngine(store: try .inMemory())
        let silent = SilentRadio()
        let first = Task { await engine.connect(silent) }
        try await eventually { await engine.state == .connecting("silent radio") }
        let radio = FakeRadio(contacts: [alice], channels: [ChannelInfo(index: 0, name: "Public", secret: Self.publicKey)])
        await engine.connect(radio)
        await first.value   // the first attempt gave up when the second began, not at its timeout
        silent.disconnect() // and its link failing later changes nothing
        #expect(await engine.state == .connected("fake radio"))
        #expect(await engine.contacts.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func stopTryingStopsTheAttempt() async throws {
        let engine = MeshEngine(store: try .inMemory())
        let attempt = Task { await engine.connect(SilentRadio()) }
        try await eventually { await engine.state == .connecting("silent radio") }
        await engine.disconnect()
        await attempt.value
        #expect(await engine.state == .disconnected)   // not "couldn't connect" from the abandoned attempt
    }

    @Test func channelMessageRepeatedByARepeater() async throws {
        let (engine, _) = try await setUp { $0.echoChannelSends = true }
        let sent = try await engine.send("hej", to: .channel(0))
        try await eventually { try engine.store.message(sent.id!)?.status == .repeated }
        let m = try #require(try engine.store.message(sent.id!))
        #expect(m.repeats == 1)
        #expect(m.path == "39")          // linked to the echo: its route and fingerprint
        #expect(m.fingerprint != nil)
        #expect(m.attempts == 1)
    }

    @Test func channelMessageNobodyRepeats() async throws {
        let (engine, radio) = try await setUp()
        let sent = try await engine.send("halo?", to: .channel(0))
        try await eventually { try engine.store.message(sent.id!)?.status == .notHeard }
        #expect(try engine.store.message(sent.id!)?.attempts == 3)
        #expect(radio.commands.filter { $0.first == 3 }.count == 3)   // the same packet three times
        let ts = radio.commands.filter { $0.first == 3 }.map { $0.subdata(in: 3..<7) }
        #expect(Set(ts).count == 1)
    }

    @Test func directMessageDeliveredOnTheSecondTry() async throws {
        let (engine, _) = try await setUp { $0.ackOnAttempt = 1 }
        let sent = try await engine.send("siema", to: .direct(alice.key))
        try await eventually { try engine.store.message(sent.id!)?.status == .delivered }
        let m = try #require(try engine.store.message(sent.id!))
        #expect(m.ackTry == 2)
        #expect(m.roundTripMs == 1834)
        #expect(m.triesFlood == [false, false])   // both on the saved route
    }

    @Test func directMessageLastTryFloodsAndKeepsTheRouteHistory() async throws {
        let (engine, radio) = try await setUp()
        let sent = try await engine.send("jesteś?", to: .direct(alice.key))
        try await eventually { try engine.store.message(sent.id!)?.status == .noAck }
        let m = try #require(try engine.store.message(sent.id!))
        #expect(m.triesFlood == [false, false, true])   // the route was forgotten before the last try
        #expect(radio.contact(alice.key)?.outPath == nil)
        let h = try #require(try engine.store.route(alice.key.hex))
        #expect(h.resetBy == "retry")
        #expect(h.previous?.path == "39")
    }

    @Test func queuedChannelMessageGetsItsPacket() async throws {
        let (engine, radio) = try await setUp()
        let text = "Ala: dzień dobry"
        radio.push(radio.rxLog(radio.groupTextPacket(key: Self.publicKey, timestamp: 1_794_000_000, text: text, path: [0x39, 0x4E]), snr: 5.5))
        radio.queue.append(radio.channelMessageFrame(slot: 0, timestamp: 1_794_000_000, text: text, hops: 2))
        radio.pushLater(Data([0x83]), ms: 50)   // messages waiting
        try await eventually { try !engine.store.messages(in: .channel(0)).isEmpty }
        let m = try #require(try engine.store.messages(in: .channel(0)).first)
        #expect(m.sender == "Ala")
        #expect(m.text == "dzień dobry")
        #expect(m.path == "394e")
        #expect(m.snr == 5.5)
        #expect(m.fingerprint != nil)
    }

    @Test func listenedChannelReadsCopiesOnce() async throws {
        let (engine, radio) = try await setUp()
        try await engine.listen(to: "#test")
        let key = ChannelCrypto.hashtagKey("#test")
        let a = radio.groupTextPacket(key: key, timestamp: 1_794_000_100, text: "Bob: test 1", path: [0x39])
        var b = a
        b[1] = 2; b.insert(0x4E, at: 3)   // the same payload over another route
        radio.push(radio.rxLog(a))
        radio.push(radio.rxLog(b))
        try await eventually { try !engine.store.messages(in: .listened("#test")).isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let msgs = try engine.store.messages(in: .listened("#test"))
        #expect(msgs.count == 1)
        #expect(msgs.first?.sender == "Bob")
        #expect(try engine.store.copies(of: msgs.first!.fingerprint!).count == 2)
    }

    @Test func roomPostsShowTheirAuthorAndStopWhenLeft() async throws {
        let (engine, radio) = try await setUp()
        radio.queue.append(radio.directMessageFrame(from: room.key, timestamp: 1_715_775_784, text: "Test raz dwa trzy", author: wenera.key.prefix(4)))
        radio.queue.append(radio.directMessageFrame(from: room.key, timestamp: 1_715_793_013, text: "kto?", author: Data([1, 2, 3, 4])))
        radio.push(Data([0x83]))
        try await eventually { try engine.store.messages(in: .direct(room.key)).count == 2 }
        let posts = try engine.store.messages(in: .direct(room.key))
        #expect(posts.map(\.sender) == ["Wenera", "01020304"])
        #expect(posts.first?.author == "4a02fdba")

        try await engine.leaveRoom(room.key)
        radio.queue.append(radio.directMessageFrame(from: room.key, timestamp: 1_715_800_000, text: "po wyjściu", author: wenera.key.prefix(4)))
        radio.push(Data([0x83]))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try engine.store.messages(in: .direct(room.key)).count == 2)   // dropped
    }

    @Test func aMessageAnotherAppFetchedIsKeptOnce() async throws {
        let (engine, radio) = try await setUp()
        let frame = radio.directMessageFrame(from: alice.key, timestamp: 1_794_000_200, text: "hej")
        radio.push(frame)   // a reply to another app's sync: not ours, but the only chance to see it
        radio.push(frame)
        try await eventually { try engine.store.messages(in: .direct(alice.key)).count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try engine.store.messages(in: .direct(alice.key)).count == 1)
        #expect(try engine.store.messages(in: .direct(alice.key)).first?.sender == "Alice")
    }

    @Test func learnedRoutesAreRecorded() async throws {
        let (engine, radio) = try await setUp()
        // a PATH packet, then the radio says it stored a route
        radio.push(radio.rxLog(Data([0x21, 0x03, 0x01, 0x02, 0x03, 0xAA, 0xBB]), snr: 6.75))
        radio.pushLater(Data([0x81]) + alice.key.bytes)
        try await eventually { try engine.store.route(alice.key.hex)?.learned != nil }
        let h = try #require(try engine.store.route(alice.key.hex))
        #expect(h.current?.path == "39")
        #expect(h.learns == 1)
        #expect(h.viaHops == 3)
        #expect(h.viaSNR == 6.75)
    }
}


/// A radio that never answers, like WiFi to an address with nothing there: connecting waits until it's
/// stopped, then fails.
final class SilentRadio: MeshTransport, @unchecked Sendable {
    let label = "silent radio"
    let frames = AsyncThrowingStream<Data, Error> { $0.finish() }
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Error>?
    private var stopped = false

    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            if stopped { c.resume(throwing: TransportError.notConnected) } else { waiting = c }
        }
    }

    func send(_ frame: Data) async throws { throw TransportError.notConnected }

    func disconnect() {
        lock.lock(); let w = waiting; waiting = nil; stopped = true; lock.unlock()
        w?.resume(throwing: TransportError.notConnected)
    }
}
