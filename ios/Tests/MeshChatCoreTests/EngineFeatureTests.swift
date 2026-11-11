import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit
import MeshChatTestSupport

/// The engine's other features against the simulated radio: channels, contacts, repeaters and rooms,
/// deleting history, the PIN and restarting.
extension EngineTests {
    @Test func joiningAndLeavingChannels() async throws {
        let (engine, radio) = try await setUp()
        let polska = try await engine.joinChannel(name: "#polska")
        #expect(polska.index == 1)
        #expect(polska.secret == ChannelCrypto.hashtagKey("#polska"))
        let secret = Data(hex: "00112233445566778899aabbccddeeff")!
        let mine = try await engine.joinChannel(name: "Rodzina", secret: secret)
        #expect(mine.index == 2)
        #expect(await engine.channels.map(\.name) == ["Public", "#polska", "Rodzina"])
        #expect(radio.channels.first { $0.index == 2 }?.secret == secret)

        try await engine.leaveChannel(1)
        #expect(await engine.channels.map(\.name) == ["Public", "Rodzina"])
        // the freed slot is used next
        #expect(try await engine.joinChannel(name: "#test").index == 1)
    }

    @Test func noFreeChannelSlot() async throws {
        let (engine, _) = try await setUp { r in
            r.channels = (0..<8).map { ChannelInfo(index: $0, name: "#c\($0)", secret: ChannelCrypto.hashtagKey("#c\($0)")) }
        }
        await #expect(throws: MeshEngine.EngineError.noFreeChannelSlot) { try await engine.joinChannel(name: "#full") }
    }

    @Test func addingAndRemovingContacts() async throws {
        let (engine, radio) = try await setUp()
        let bob = PublicKey(Data(repeating: 0xE5, count: 32))!
        #expect(try await engine.addContact(key: bob, name: "Bob", type: .companion))
        #expect(await engine.contacts[bob]?.name == "Bob")
        #expect(radio.contact(bob)?.type == .companion)
        #expect(try await engine.addContact(key: bob, name: "Bob", type: .companion) == false)   // already there

        try await engine.removeContact(bob)
        #expect(await engine.contacts[bob] == nil)
        #expect(radio.contact(bob) == nil)
    }

    @Test func removingManyContactsAndFavourites() async throws {
        let (engine, radio) = try await setUp()
        let keys = (1...25).map { PublicKey(Data([0xA0, UInt8($0)]) + Data(repeating: 0x11, count: 30))! }
        for (i, k) in keys.enumerated() { _ = try await engine.addContact(key: k, name: "RPT \(i)", type: .repeater) }
        let gone = PublicKey(Data([0xEE]) + Data(repeating: 0x22, count: 31))!   // already gone from the radio

        let counts = Counter()
        let done = try await engine.removeContacts(Array(keys.prefix(20)) + [gone]) { await counts.add($0) }
        #expect(done == 21)   // the one the radio didn't have counts as done
        #expect(await counts.values == Array(1...21))
        #expect(await engine.contacts.count == radio.contacts.count)
        #expect(Set(radio.contacts.map(\.key)).isDisjoint(with: keys.prefix(20)))
        #expect(keys.suffix(5).allSatisfy { radio.contact($0) != nil })

        // a favourite, kept with its route
        let k = keys[22]
        let modified = try #require(radio.contact(k)?.lastModified)
        try await engine.setFavourite(k, true)
        #expect(radio.contact(k)?.isFavourite == true)
        #expect(radio.contact(k)?.lastModified == modified)   // a star isn't hearing it
        #expect(await engine.contacts[k]?.isFavourite == true)
        try await engine.setFavourite(k, false)
        #expect(radio.contact(k)?.isFavourite == false)
        await #expect(throws: MeshEngine.EngineError.unknownContact) { try await engine.setFavourite(gone, true) }
    }

    @Test func starsWhatYouUse() async throws {
        let (engine, radio) = try await setUp()
        let ania = PublicKey(Data([0xC1]) + Data(repeating: 0x44, count: 31))!
        let zosia = PublicKey(Data([0xC2]) + Data(repeating: 0x44, count: 31))!
        _ = try await engine.addContact(key: ania, name: "Ania", type: .companion)
        _ = try await engine.addContact(key: zosia, name: "Zosia", type: .companion)

        // off (as the engine starts): a message doesn't star anyone
        try await engine.send("hej", to: .direct(zosia))
        try await Task.sleep(for: .milliseconds(300))
        #expect(radio.contact(zosia)?.isFavourite == false)

        await engine.setStarWhatYouUse(true)
        try await engine.send("cześć", to: .direct(ania))
        for _ in 0..<50 where radio.contact(ania)?.isFavourite != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(radio.contact(ania)?.isFavourite == true)
        #expect(await engine.contacts[ania]?.isFavourite == true)
    }

    @Test func removingContactsStopsWhenCancelled() async throws {
        let (engine, radio) = try await setUp()
        let keys = (1...30).map { PublicKey(Data([0xB0, UInt8($0)]) + Data(repeating: 0x33, count: 30))! }
        for (i, k) in keys.enumerated() { _ = try await engine.addContact(key: k, name: "S \(i)", type: .sensor) }
        let before = radio.contacts.count
        let task = Task { try await engine.removeContacts(keys) { n in if n == 5 { withUnsafeCurrentTask { $0?.cancel() } } } }
        let done = try await task.value
        #expect(done == 5)
        #expect(radio.contacts.count == before - 5)
    }

    @Test func reachCheckAnswers() async throws {
        let prefix = Data([0xD3, 0xAB, 0x6E, 0xFF, 0x01, 0x23, 0x45, 0x67])
        let (engine, _) = try await setUp { $0.reachAnswers = [(prefix: prefix, snrThere: 5.25, snrHere: 2.5)] }
        let answers = try await engine.checkReach()
        #expect(answers.map(\.keyPrefix) == [prefix])
        #expect(answers.first?.snrThere == 5.25 && answers.first?.snrHere == 2.5)
    }

    @Test func askingForReadings() async throws {
        let (engine, radio) = try await setUp()
        // a person: asked directly
        let a = try await engine.telemetry(alice.key)
        #expect(a.error == nil)
        #expect(a.readings.map(\.text) == ["4.12 V", "21.5 °C"])
        #expect(try engine.store.telemetryAnswer(alice.key.hex)?.data == a.data)   // kept
        #expect(radio.commands.contains { $0.first == 39 } && !radio.commands.contains { $0.first == 26 })

        // a repeater: as a guest first, then out again
        let rep = PublicKey(Data([0x7A]) + Data(repeating: 0xE5, count: 31))!
        _ = try await engine.addContact(key: rep, name: "Żarki RPT", type: .repeater)
        let r = try await engine.telemetry(rep)
        #expect(r.readings.first?.label == "Battery")
        let codes = radio.commands.compactMap(\.first)
        let login = try #require(codes.lastIndex(of: 26)), ask = try #require(codes.lastIndex(of: 39)), out = try #require(codes.lastIndex(of: 29))
        #expect(login < ask && ask < out)

        // rooms aren't asked (logging in would join them)
        await #expect(throws: MeshEngine.EngineError.unknownContact) { try await engine.telemetry(room.key) }
    }

    @Test func aPersonWhoDoesntShareReadings() async throws {
        let (engine, _) = try await setUp { $0.shareNoTelemetry = true }
        let a = try await engine.telemetry(alice.key)
        #expect(a.data == nil && a.readings.isEmpty)
        #expect(a.error?.hasPrefix("No answer. They may not share readings") == true)
    }

    @Test func askingARepeaterForStatusAndNeighbours() async throws {
        let (engine, radio) = try await setUp { r in
            r.neighbours = [(Data([0x39, 0x01, 0x02, 0x03]), 120, 29), (Data([0x4e, 0x0a, 0x0b, 0x0c]), 3600, -8)]
        }
        let rep = PublicKey(Data([0x77]) + Data(repeating: 0xF6, count: 31))!
        _ = try await engine.addContact(key: rep, name: "Żarki RPT", type: .repeater)

        let a = try await engine.query(rep)
        #expect(a.ok && a.error == nil)
        #expect(a.role == "read-write" && !a.admin)
        let s = try #require(a.status.flatMap(NodeStatus.init))
        #expect(s.batteryMillivolts == 4120 && s.uptimeSeconds == 172_800 && s.noiseFloor == -117 && s.lastSNR == 7.25)
        #expect(a.neighboursTotal == 2)
        #expect(a.neighbours?.map(\.prefix) == ["39010203", "4e0a0b0c"])
        #expect(a.neighbours?.map(\.snr) == [7.25, -2])
        #expect(radio.commands.contains { $0.first == 29 })            // logged out again
        #expect(try engine.store.liveAnswer(rep.hex)?.neighbours?.count == 2)
        #expect(try engine.store.room(rep.hex) == nil)                  // a repeater isn't joined
    }

    /// The case seen on the real mesh: the first query flooded and was answered; the next ones went on
    /// the route that answer brought and got nothing back. Now the query forgets the route and floods.
    @Test func aRouteThatStoppedWorkingFallsBackToFlood() async throws {
        let rep = Contact(key: PublicKey(Data([0xA1]) + Data(repeating: 0xF7, count: 31))!, type: .repeater,
                          outPath: OutPath(hashSize: 2, hops: [Data([0x39, 0x00]), Data([0x83, 0xD7])]), name: "STA Os. PKP")
        let (engine, radio) = try await setUp { r in
            r.add(rep)
            r.routeIsDead = true
            r.neighbours = [(Data([0x39, 0x00, 0x01, 0x02]), 60, 32)]
        }
        let a = try await engine.query(rep.key)
        #expect(a.ok && a.status.flatMap(NodeStatus.init) != nil && a.neighbours?.count == 1)
        let resets = radio.commands.filter { $0.first == 13 && $0.dropFirst() == rep.key.bytes }
        #expect(resets.count == 1)                                     // forgotten once, then flooded
        #expect(radio.commands.filter { $0.first == 26 }.count == 2)    // the login: on the route, then by flood
        #expect(radio.contact(rep.key)?.outPath == nil)
        #expect(try engine.store.route(rep.key.hex)?.resetBy == "retry")
    }

    @Test func aRefusedLoginDoesntFlood() async throws {
        let rep = Contact(key: PublicKey(Data([0xA2]) + Data(repeating: 0xF8, count: 31))!, type: .repeater,
                          outPath: OutPath(hashSize: 1, hops: [Data([0x39])]), name: "Locked")
        let (engine, radio) = try await setUp { r in r.add(rep); r.refuseLogins = true }
        let a = try await engine.query(rep.key, password: "wrong")
        #expect(!a.ok && a.error?.contains("refused") == true)
        #expect(!radio.commands.contains { $0.first == 13 })            // an answer, even a no: the route works
        #expect(radio.contact(rep.key)?.outPath != nil)
    }

    @Test func adminCommandsAndTheirAnswers() async throws {
        let rep = Contact(key: PublicKey(Data([0xA3]) + Data(repeating: 0xF9, count: 31))!, type: .repeater, name: "Fake RPT")
        let (engine, radio) = try await setUp { $0.add(rep) }
        await engine.runCommand("get name", on: rep.key)
        await engine.runCommand("ver", on: rep.key)
        try await eventually { (await engine.consoles[rep.key]?.count ?? 0) == 4 }
        let lines = try #require(await engine.consoles[rep.key])
        let commands = lines.filter(\.isCommand)
        #expect(commands.map(\.text) == ["get name", "ver"] && commands.allSatisfy { $0.status == .sent })
        let answers = AdminConsole.answers(lines)
        #expect(answers[commands[0].id]?.text == "> Fake RPT")
        #expect(answers[commands[1].id]?.text.hasPrefix("v1.11.0") == true)
        #expect(AdminConsole.values(lines)["name"] == "Fake RPT")
        #expect(radio.adminCommands == ["get name", "ver"])
        #expect(try engine.store.messages(in: .direct(rep.key)).isEmpty)   // answers aren't chat
    }

    @Test func adminPasswordsAreMaskedInTheLog() async throws {
        let rep = Contact(key: PublicKey(Data([0xA4]) + Data(repeating: 0xFA, count: 31))!, type: .repeater, name: "Mine")
        let (engine, radio) = try await setUp { $0.add(rep) }
        await engine.runCommand("password hunter2", on: rep.key)
        try await eventually { (await engine.consoles[rep.key]?.count ?? 0) == 2 }
        let texts = try #require(await engine.consoles[rep.key]).map(\.text)
        #expect(texts == ["password \u{2022}\u{2022}\u{2022}\u{2022}", "password now: \u{2022}\u{2022}\u{2022}\u{2022}"])
        #expect(radio.adminCommands == ["password hunter2"])   // the repeater gets it (encrypted on the air)
    }

    @Test func aCommandToANodeThatIsntAContact() async throws {
        let (engine, radio) = try await setUp()
        let stranger = PublicKey(Data(repeating: 0x5E, count: 32))!
        await engine.runCommand("reboot", on: stranger)
        #expect(await engine.consoles[stranger]?.map(\.status) == [.failed])
        #expect(radio.adminCommands.isEmpty)
    }

    @Test func joiningARoomAsAGuest() async throws {
        let (engine, radio) = try await setUp { $0.loginRole = 0 }
        let a = try await engine.query(room.key)
        #expect(a.ok && a.role == "guest")
        let m = try #require(try engine.store.room(room.key.hex))
        #expect(!m.left && m.role == "guest" && m.loginAt != nil)
        #expect(!RoomRole.canPost(m.role))
        #expect(RoomStatusCheck.posts(a).map { $0 == 12 && $1 == 30 } == true)
        #expect(!radio.commands.contains { $0.first == 29 })           // rooms stay logged in: that's membership
    }

    @Test func aRefusedLogin() async throws {
        let (engine, _) = try await setUp { $0.refuseLogins = true }
        let a = try await engine.query(room.key, password: "wrong")
        #expect(!a.ok)
        #expect(a.error?.contains("refused") == true)
        #expect(try engine.store.room(room.key.hex) == nil)
    }

    @Test func deletingHistory() async throws {
        let (engine, _) = try await setUp()
        func add(_ c: ConversationID, _ text: String) throws -> Message {
            try engine.store.insert(Message(senderTimestamp: 1, conversation: c, direction: .incoming, sender: "Ala", text: text, status: .received))
        }
        let first = try add(.channel(0), "jeden")
        _ = try add(.channel(0), "dwa")
        _ = try add(.channel(0), "trzy")
        _ = try add(.direct(alice.key), "prywatnie")

        try await engine.deleteMessage(first.id!)
        #expect(try engine.store.messages(in: .channel(0)).map(\.text) == ["dwa", "trzy"])
        #expect(try await engine.deleteConversation(.channel(0)) == 2)
        #expect(try engine.store.messages(in: .channel(0)).isEmpty)
        #expect(try engine.store.messages(in: .direct(alice.key)).count == 1)   // other conversations untouched
    }

    @Test func settingTheBluetoothPin() async throws {
        let (engine, radio) = try await setUp()
        try await engine.setDevicePin("654321")
        #expect(radio.pin == 654_321)
        await #expect(throws: MeshEngine.EngineError.badPin) { try await engine.setDevicePin("012345") }
        #expect(radio.pin == 654_321)
        #expect(radio.commands.filter { $0.first == 37 }.count == 1)    // the bad one never sent
    }

    @Test func restartingTheRadioDropsTheLink() async throws {
        let (engine, radio) = try await setUp()
        try await engine.reboot()
        #expect(radio.rebooted)
        #expect(radio.commands.last == Data([19]) + Data("reboot".utf8))
        try await eventually { await engine.state != .connected("fake radio") }
    }
}

/// Reads a room's post counts from a stored answer.
enum RoomStatusCheck {
    static func posts(_ a: LiveAnswer) -> (Int, Int)? {
        a.status.flatMap(NodeStatus.init)?.roomPosts.map { ($0.posted, $0.pushes) }
    }
}

/// Collects progress counts from another task.
actor Counter {
    private(set) var values: [Int] = []
    func add(_ n: Int) { values.append(n) }
}
