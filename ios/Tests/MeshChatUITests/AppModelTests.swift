import Foundation
import MeshChatCore
import MeshChatTestSupport
import MeshCoreKit
import Testing
@testable import MeshChatUI

/// The app model every screen reads, against the simulated radio: what the chat list, the tab badge and
/// moving between tabs rely on.
@Suite("App model", .serialized) @MainActor
struct AppModelTests {
    static let publicKey = Data(hex: "8b3387e9c5cdea6ac9e5edbaa115cd72")!
    let alice = Contact(key: PublicKey(Data(repeating: 0xB2, count: 32))!, type: .companion, name: "Alice",
                        position: Position(latitude: 50.80, longitude: 19.10))
    let room = Contact(key: PublicKey(Data(repeating: 0xC3, count: 32))!, type: .room, name: "LUNA")

    func make(defaults: UserDefaults? = nil) async throws -> (AppModel, FakeRadio, UserDefaults) {
        let d = defaults ?? UserDefaults(suiteName: "meshchat-tests-\(UUID().uuidString)")!
        let radio = FakeRadio(contacts: [alice, room], channels: [ChannelInfo(index: 0, name: "Public", secret: Self.publicKey)])
        let model = AppModel(engine: MeshEngine(store: try .inMemory()), defaults: d)
        await model.engine.connect(radio)
        try await eventually { model.isConnected && model.me != nil && model.contacts.count == 2 }
        return (model, radio, d)
    }

    func eventually(_ check: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < end {
            if check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out")
    }

    @Test func followsTheRadiosNetwork() async throws {
        let (model, radio, d) = try await make()
        let south = "869.618/62.5/6", national = "869.618/62.5/8"
        #expect(model.network == south)
        #expect(model.networkName == "MeshCore Południe")
        // on another network, Alice's advert is heard
        try await model.engine.apply(RadioProfile.suggested[1])
        try await eventually { model.network == national }
        radio.push(radio.rxLog(radio.advertPacket(key: alice.key, type: .companion, name: "Alice")))
        try await eventually { model.reloadHeard(); return model.heard.map(\.name) == ["Alice"] }
        // back on this one, she's heard only elsewhere: listed apart, off the map, and the other network kept
        try await model.engine.apply(RadioProfile.suggested[0])
        try await eventually { model.network == south }
        #expect(model.heard.isEmpty)
        #expect(model.onlyElsewhere(alice))
        #expect(model.contactsHere.map(\.name) == ["LUNA"])
        #expect(model.heardByNetwork.others.map(\.network) == [national])
        #expect(d.string(forKey: "network") == south)   // remembered for when the radio isn't connected
        #expect(AppModel(engine: MeshEngine(store: model.store), defaults: d).network == south)
    }

    @Test func mirrorsTheRadio() async throws {
        let (model, _, _) = try await make()
        #expect(model.me?.name == "MrE")
        #expect(model.device?.model == "Fake Board")
        #expect(model.channels.map(\.name) == ["Public"])
        #expect(model.title(of: .channel(0)) == "Public")
        #expect(model.title(of: .direct(alice.key)) == "Alice")
        #expect(model.title(of: .channel(5)) == "Channel 5")
        #expect(model.unreadCount == 0)
    }

    @Test func aDirectMessageIsUnreadUntilOpened() async throws {
        let (model, radio, defaults) = try await make()
        var notified: [Message] = []
        model.onIncoming = { m, _ in notified.append(m) }
        radio.queue.append(radio.directMessageFrame(from: alice.key, timestamp: 1_794_000_000, text: "hej, jesteś?"))
        radio.push(Data([0x83]))
        try await eventually { model.conversations[.direct(alice.key)] != nil }
        #expect(model.isUnread(.direct(alice.key)))
        #expect(model.unreadCount == 1)
        #expect(model.directList == [.direct(alice.key)])
        #expect(model.roomList.isEmpty)
        try await eventually { !notified.isEmpty }
        #expect(notified.first?.text == "hej, jesteś?")

        model.markRead(.direct(alice.key))
        #expect(model.unreadCount == 0)
        // kept for the next launch
        #expect((defaults.dictionary(forKey: "lastRead") as? [String: NSNumber])?["dm:\(alice.key.hex)"] != nil)
    }

    @Test func roomsAreListedApartAndDropOutWhenLeft() async throws {
        let (model, radio, _) = try await make()
        radio.queue.append(radio.directMessageFrame(from: room.key, timestamp: 1_794_000_100, text: "witajcie", author: Data([1, 2, 3, 4])))
        radio.push(Data([0x83]))
        try await eventually { !model.roomList.isEmpty }
        #expect(model.roomList == [.direct(room.key)])
        #expect(model.isRoom(.direct(room.key)))
        #expect(model.directList.isEmpty)
        #expect(model.unreadCount == 1)

        try await model.engine.leaveRoom(room.key)
        try await eventually { model.roomList.isEmpty }
        #expect(model.unreadCount == 0)   // a room you left doesn't count
    }

    @Test func swipingDeletesConversations() async throws {
        let (model, radio, _) = try await make()
        // a DM: its messages go, the contact stays
        radio.queue.append(radio.directMessageFrame(from: alice.key, timestamp: 1_794_000_000, text: "hej"))
        radio.push(Data([0x83]))
        try await eventually { model.directList == [.direct(alice.key)] }
        model.open(.direct(alice.key))
        try await model.delete(.direct(alice.key))
        try await eventually { model.directList.isEmpty }
        #expect(model.contacts[alice.key] != nil)
        #expect(model.openConversation == nil)

        // a channel: left on the radio (its slot freed) and its messages deleted
        _ = try await model.engine.joinChannel(name: "#test")
        try await eventually { model.channels.map(\.name) == ["Public", "#test"] }
        try await model.delete(.channel(1))
        try await eventually { model.channels.map(\.name) == ["Public"] }
        #expect(radio.channels.map(\.name) == ["Public"])

        // a room: left, posts kept when asked
        radio.queue.append(radio.directMessageFrame(from: room.key, timestamp: 1_794_000_100, text: "witajcie", author: Data([1, 2, 3, 4])))
        radio.push(Data([0x83]))
        try await eventually { model.roomList == [.direct(room.key)] }
        try await model.delete(.direct(room.key), keepingPosts: true)
        try await eventually { model.roomList.isEmpty }
        #expect(model.conversations[.direct(room.key)]?.count == 1)
    }

    @Test func listenedChannelsAppear() async throws {
        let (model, _, _) = try await make()
        try await model.engine.listen(to: "Test")
        try await eventually { model.listened.map(\.name) == ["#test"] }
        #expect(model.title(of: .listened("#test")) == "#test")
    }

    @Test func movingBetweenTabs() async throws {
        let (model, _, _) = try await make()
        model.tab = .settings
        model.open(.channel(0))
        #expect(model.tab == .chats && model.openConversation == .channel(0))

        let home = MapRoute.Stop(id: "home", name: "You", kind: .home, position: Position(latitude: 50.8, longitude: 19.1))
        let route = MapRoute(title: "Ala → you", stops: [home, home], hidden: 0, hops: 1)
        model.tab = .chats
        model.showRoute(route)
        #expect(model.tab == .map && model.mapRoute == route && model.mapFocus == nil)
        model.showOnMap(alice.key.hex)
        #expect(model.tab == .map && model.mapFocus == alice.key.hex && model.mapRoute == nil)

        model.showRepeater("39aa")
        #expect(model.tab == .repeaters && model.repeaterFocus == "39aa")
    }

    @Test func homeIsKeptOnThisDevice() async throws {
        let (model, _, defaults) = try await make()
        model.home = Position(latitude: 50.0647, longitude: 19.9450)
        let again = AppModel(engine: MeshEngine(store: try .inMemory()), defaults: defaults)
        #expect(again.home == Position(latitude: 50.0647, longitude: 19.9450))
        #expect(again.directory.home == again.home)
        model.home = nil
        #expect(AppModel(engine: MeshEngine(store: try .inMemory()), defaults: defaults).home == nil)
    }

    @Test func reconnectsAfterTheRadioRestarts() async throws {
        let (model, first, _) = try await make()
        let second = FakeRadio(contacts: [alice, room], channels: [ChannelInfo(index: 0, name: "Public", secret: Self.publicKey)])
        model.makeTransport = { _ in second }
        model.retryBase = .milliseconds(50)
        model.savedRadio = .wifi(host: "meshcore.local", port: 5000)
        try await model.engine.reboot()
        #expect(first.rebooted)
        try await eventually { second.commands.contains { $0.first == 1 } && model.isConnected }
        #expect(model.me?.name == "MrE")
    }

    @Test func forgettingTheRadioStopsReconnecting() async throws {
        let (model, _, _) = try await make()
        let second = FakeRadio(contacts: [], channels: [])
        model.makeTransport = { _ in second }
        model.retryBase = .milliseconds(20)
        model.savedRadio = .wifi(host: "meshcore.local", port: 5000)
        await model.forgetRadio()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.isConnected)
        #expect(second.commands.isEmpty)
    }

    @Test func theSavedRadioIsRemembered() async throws {
        let d = UserDefaults(suiteName: "meshchat-tests-\(UUID().uuidString)")!
        let model = AppModel(engine: MeshEngine(store: try .inMemory()), defaults: d)
        #expect(model.savedRadio == nil)
        model.savedRadio = .wifi(host: "meshcore.local", port: 5000)
        #expect(AppModel(engine: MeshEngine(store: try .inMemory()), defaults: d).savedRadio == .wifi(host: "meshcore.local", port: 5000))
        await model.forgetRadio()
        #expect(AppModel(engine: MeshEngine(store: try .inMemory()), defaults: d).savedRadio == nil)
    }
}
