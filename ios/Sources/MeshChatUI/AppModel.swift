import Foundation
import MeshChatCore
import MeshCoreKit
import Observation

/// The radio the app connects to, remembered across launches.
public enum SavedRadio: Codable, Hashable, Sendable {
    case bluetooth(id: UUID, name: String)
    case wifi(host: String, port: UInt16)
    /// the demo's simulated radio (DemoMesh)
    case demo

    public var title: String {
        switch self {
        case .bluetooth(_, let name): name
        case .wifi(let host, _): host
        case .demo: String(localized: "Demo radio")
        }
    }

    /// Which radio this is, whatever its name now.
    public var key: String {
        switch self {
        case .bluetooth(let id, _): "bt:\(id.uuidString)"
        case .wifi(let host, let port): "wifi:\(host.lowercased()):\(port)"
        case .demo: "demo"
        }
    }

    func transport() -> MeshTransport {
        switch self {
        case .bluetooth(let id, let name): BluetoothTransport(identifier: id, name: name)
        case .wifi(let host, let port): TCPTransport(host: host, port: port)
        case .demo: DemoMesh.makeRadio()
        }
    }
}

/// What the screens show, kept current from the engine. Main actor: SwiftUI reads it directly.
@MainActor @Observable
public final class AppModel {
    public let engine: MeshEngine
    /// where the saved radio, read markers and home are kept
    private let defaults: UserDefaults
    public var store: Store { engine.store }

    public private(set) var connection: MeshEngine.ConnectionState = .disconnected
    public private(set) var me: SelfInfo?
    public private(set) var device: DeviceInfo?
    /// The radio's battery, as last asked (`refreshBattery`); nil when not connected or not known yet.
    public private(set) var battery: BatteryInfo?
    @ObservationIgnored private var batteryAt = Date.distantPast
    public private(set) var contacts: [PublicKey: Contact] = [:]
    public private(set) var channels: [ChannelInfo] = []
    public private(set) var listened: [ListenedChannel] = []
    public private(set) var rooms: [String: RoomMembership] = [:]
    public private(set) var conversations: [ConversationID: ConversationSummary] = [:]
    /// bumped on every change to a conversation's messages, so its screen reloads
    public private(set) var messageVersion: [ConversationID: Int] = [:]
    public private(set) var packetVersion = 0
    public private(set) var routeVersion = 0
    /// the last message read in each conversation (unread markers)
    public var lastRead: [String: Int64] {
        didSet { defaults.set(lastRead.mapValues(NSNumber.init(value:)), forKey: "lastRead") }
    }

    /// Where distances are measured from (and the map centres): set in Settings. Never leaves the device.
    public var home: Position? {
        didSet { defaults.set(try? JSONEncoder().encode(home), forKey: "home") }
    }

    /// The radio's own position, as last read from it (kept for when it isn't connected).
    public private(set) var radioPosition: Position? {
        didSet { if radioPosition != oldValue { defaults.set(try? JSONEncoder().encode(radioPosition), forKey: "radioPosition") } }
    }

    /// Your saved networks (radio profiles), kept on this iPhone; the suggested ones are put in once.
    public var radioProfiles = RadioProfileStore() {
        didSet { defaults.set(try? JSONEncoder().encode(radioProfiles), forKey: "radioProfiles") }
    }

    /// The saved network the radio is on now, if any ("Custom" otherwise).
    public var currentProfile: RadioProfile? { me.flatMap { radioProfiles.match($0.radio) } }

    /// Where distances to nodes are measured from: home if you set one, else where your radio is.
    public var distanceOrigin: Position? { home ?? radioPosition }

    /// Each repeater's command line this session (admin commands and their answers).
    public private(set) var consoles: [PublicKey: [ConsoleLine]] = [:]

    /// The network the radio is on (a NetworkKey), or was on when last connected: Nodes, the map,
    /// Repeaters, the packet log and the reach check show what was heard on it. Chats, contacts, rooms
    /// and routes are the same whatever the network.
    public private(set) var network: String? {
        didSet {
            guard network != oldValue else { return }
            defaults.set(network, forKey: "network")
            reloadHeard()
        }
    }

    /// The network's name: "MeshCore Południe", or its settings when it isn't a saved one.
    public var networkName: String? { network.map { radioProfiles.name(forNetwork: $0) } }

    /// What the radio heard, as seen from its network (refreshed as packets arrive).
    public private(set) var heardByNetwork = HeardByNetwork(network: nil)

    /// Nodes whose adverts the radio heard on its network.
    public var heard: [HeardNode] { heardByNetwork.here }

    /// The radio's contacts, but for those heard only on other networks.
    public var contactsHere: [Contact] { contacts.values.filter { !heardByNetwork.onlyElsewhere.contains($0.key.hex) } }

    /// A contact heard only on other networks, not on the radio's.
    public func onlyElsewhere(_ c: Contact) -> Bool { heardByNetwork.onlyElsewhere.contains(c.key.hex) }

    /// Names the repeater IDs in paths.
    public var directory: NodeDirectory { NodeDirectory(contacts: Array(contacts.values), heard: heard, home: distanceOrigin) }

    public var savedRadio: SavedRadio? {
        didSet { defaults.set(try? JSONEncoder().encode(savedRadio), forKey: "radio") }
    }

    /// Radios connected to before, newest first (Bluetooth and WiFi), to switch between in Settings.
    public private(set) var recentRadios: [SavedRadio] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(recentRadios), forKey: "recentRadios") }
    }

    /// Try again by itself when the link drops (on by default).
    public var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: "autoReconnect") }
    }

    public func forget(_ radio: SavedRadio) { recentRadios.removeAll { $0.key == radio.key } }

    /// People you've blocked: their messages are hidden here and don't notify (see BlockList).
    public private(set) var blockList = BlockList() {
        didSet { defaults.set(try? JSONEncoder().encode(blockList), forKey: "blocked") }
    }

    public func block(name: String, key: String?) { blockList.block(name: name, key: key) }
    public func unblock(_ e: BlockList.Entry) { blockList.unblock(e) }

    /// A contact you've blocked.
    public func isBlocked(_ c: Contact) -> Bool { blockList.isBlocked(name: c.name, key: c.key.hex) }

    // MARK: moving between tabs

    public enum Tab: Hashable, Sendable { case chats, map, repeaters, nodes, settings }
    public var tab: Tab = .chats
    /// a conversation to open in Chats
    public var openConversation: ConversationID?
    /// a point to centre the map on
    public var mapFocus: String?
    /// a message's route to draw on the map, instead of every node
    public var mapRoute: MapRoute?
    /// a repeater to show in Repeaters
    public var repeaterFocus: String?

    /// a meshcore:// link opened from outside, waiting to be shown
    public var pendingLink: String?

    /// Conversations with unread messages (the Chats tab badge).
    public var unreadCount: Int { conversations.keys.filter { isUnread($0) && !isLeftRoom($0) && !blockList.hides($0) }.count }

    func isLeftRoom(_ c: ConversationID) -> Bool {
        if case .direct(let k) = c { return rooms[k.hex]?.left == true }
        return false
    }

    public func open(_ c: ConversationID) { openConversation = c; tab = .chats }
    public func showOnMap(_ id: String) { mapRoute = nil; mapFocus = id; tab = .map }
    public func showRoute(_ route: MapRoute) { mapRoute = route; mapFocus = nil; tab = .map }
    public func showRepeater(_ key: String) { repeaterFocus = key; tab = .repeaters }

    @ObservationIgnored private var analyses: [String: (version: Int, task: Task<RepeaterAnalysis, Never>)] = [:]

    /// The packet log of the last `days` on the radio's network, worked out off the main thread: shared by
    /// the Repeaters tab, a repeater's page and the map (callers at the same time share one run), and
    /// worked out again only after another 25 packets.
    public func repeaterAnalysis(days: Int) async -> RepeaterAnalysis {
        let version = packetVersion / 25
        let id = "\(days)/\(network ?? "")"
        if let a = analyses[id], a.version == version { return await a.task.value }
        let store = store, dir = directory, net = network
        let task = Task.detached(priority: .utility) {
            let since = Date.now.addingTimeInterval(-Double(days) * 86400)
            return RepeaterAnalysis(packets: (try? store.recentPackets(since: since, network: net)) ?? [],
                                    channelRoutes: (try? store.channelRoutes(since: since, network: net)) ?? [], directory: dir, days: days)
        }
        analyses[id] = (version, task)
        return await task.value
    }

    /// Called for new incoming messages, and whether they're the backlog fetched on reconnecting (the app
    /// decides on notifications from them).
    public var onIncoming: ((Message, _ backlog: Bool) -> Void)?
    /// Called when a conversation is read here (the app clears its notifications and the badge).
    public var onRead: ((ConversationID) -> Void)?

    // MARK: notifications

    /// What notifies, and how (Settings › Notifications and each conversation's menu).
    public var notificationSettings: NotificationSettings {
        didSet {
            defaults.set(try? JSONEncoder().encode(notificationSettings), forKey: "notifications")
            onNotificationSettings?()
        }
    }
    /// Called when the settings change (the app updates the badge).
    public var onNotificationSettings: (() -> Void)?

    /// iOS's answer about notifications, kept current by the app.
    public enum NotificationPermission: Sendable { case unknown, notAsked, allowed, denied }
    public var notificationPermission: NotificationPermission = .unknown
    /// Asks iOS (the app supplies it).
    public var askNotificationPermission: (() async -> Void)?
    /// Settings › Notifications should open (iOS's own settings link here).
    public var showNotificationSettings = false

    /// The conversation on screen, while the app is in front: it doesn't notify.
    public var visibleConversation: ConversationID?

    public func kind(of c: ConversationID) -> ConversationKind {
        switch c {
        case .channel: .channel
        case .listened: .listened
        case .direct: isRoom(c) ? .room : .direct
        }
    }

    /// Whether a reply can go from a notification: not a listened channel, an unknown sender or a room
    /// you can only read.
    public func canReply(_ c: ConversationID) -> Bool {
        switch c {
        case .channel: true
        case .listened: false
        case .direct(let k):
            contacts[k] != nil && (rooms[k.hex].map { $0.left || RoomRole.canPost($0.role) } ?? true)
        }
    }

    /// What the notification decision needs to know about a message's conversation.
    public func notificationContext(for m: Message, backlog: Bool, appActive: Bool, now: Date = .now) -> NotificationContext {
        NotificationContext(myName: me?.name, kind: kind(of: m.conversation), title: title(of: m.conversation),
                            canReply: canReply(m.conversation), visible: appActive ? visibleConversation : nil,
                            isBacklog: backlog, now: now)
    }

    /// Unread conversations that notify every message (a channel left on "mentions only" doesn't count,
    /// or a busy one would keep it up for good).
    var unreadNotifying: [ConversationID] {
        conversations.keys.filter { c in
            isUnread(c) && !isLeftRoom(c) && notificationSettings.effectiveLevel(for: c, kind: kind(of: c)) == .all
        }
    }

    /// The app icon's number.
    public var badgeCount: Int {
        notificationSettings.badgeCount(unread: conversations.keys.filter { isUnread($0) && !isLeftRoom($0) }.map { ($0, kind(of: $0)) })
    }

    /// For the lock screen's status: how many conversations wait, and the newest message among them.
    public var unreadSummary: (count: Int, newest: Message?) {
        let list = unreadNotifying
        let newest = list.max { latest($0) < latest($1) }.flatMap { conversations[$0] }.flatMap { try? store.message($0.lastID) }
        return (list.count, newest)
    }

    // MARK: where your node says it is

    /// What your adverts give as your position: none, one you set, or the phone's, kept current while
    /// MeshChat is open.
    public enum LocationSource: String, Codable, Sendable, CaseIterable {
        case none, fixed, phone
        public var label: String {
            switch self {
            case .none: String(localized: "None")
            case .fixed: String(localized: "Fixed")
            case .phone: String(localized: "Phone's GPS")
            }
        }
    }

    /// The choice made here; before one, what the radio does (sharing or not).
    public var locationSource: LocationSource {
        get { locationChoice ?? (me.map { $0.advertLocationPolicy == 0 ? .none : .fixed } ?? .none) }
        set { locationChoice = newValue }
    }
    private var locationChoice: LocationSource? {
        didSet { defaults.set(locationChoice?.rawValue, forKey: "locationSource") }
    }
    /// the phone's position last sent to the radio, and when
    public private(set) var lastPhoneFix: (position: Position, at: Date)?

    /// Sets what adverts share: nothing, `position`, or (for the phone's GPS) the first fix, then the
    /// updates `phoneMoved` sends.
    public func setLocation(_ source: LocationSource, position: Position? = nil) async throws {
        try await engine.setLocation(shared: source != .none, position: source == .none ? nil : position)
        locationChoice = source
        if source == .phone, let position { lastPhoneFix = (position, .now) }
    }

    /// A new fix from the phone: sent on when it moved over 200 m, or 30 minutes on.
    public func phoneMoved(to p: Position, now: Date = .now) async {
        guard locationSource == .phone, isConnected else { return }
        if let last = lastPhoneFix, Geo.km(last.position, p) < 0.2, now.timeIntervalSince(last.at) < 30 * 60 { return }
        if (try? await engine.setLocation(shared: true, position: p)) != nil { lastPhoneFix = (p, now) }
    }

    /// Keep running in the background while connected over WiFi (iOS pauses apps otherwise, and the link
    /// with them). Bluetooth needs none of this.
    public var keepRunningInBackground: Bool {
        didSet { defaults.set(keepRunningInBackground, forKey: "keepRunningInBackground") }
    }
    /// The app keeps itself running in the background right now (the app sets it).
    public var runsInBackground = false
    /// Location access is off, so it can't (the app sets it).
    public var backgroundBlocked = false

    /// The radio's status on the lock screen, Dynamic Island and always-on display (a Live Activity).
    public var lockScreenStatus: Bool {
        didSet { defaults.set(lockScreenStatus, forKey: "lockScreenStatus") }
    }
    /// iOS lets MeshChat show Live Activities (the app keeps it current).
    public var liveActivitiesAllowed = true

    /// Sends a reply typed into a notification: reconnects first if the link is down (WiFi drops in the
    /// background), giving up after `timeout`.
    public func reply(_ text: String, to c: ConversationID, timeout: Duration = .seconds(8)) async throws {
        if !isConnected {
            await reconnect(force: true)
            let end = ContinuousClock.now + timeout
            while !isConnected, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(200)) }
        }
        guard isConnected else { throw MeshEngine.EngineError.notConnected }
        _ = try await engine.send(text, to: c)
    }

    public init(engine: MeshEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        savedRadio = (defaults.data(forKey: "radio")).flatMap { try? JSONDecoder().decode(SavedRadio.self, from: $0) }
        lastRead = ((defaults.dictionary(forKey: "lastRead") as? [String: NSNumber]) ?? [:]).mapValues(\.int64Value)
        home = defaults.data(forKey: "home").flatMap { try? JSONDecoder().decode(Position.self, from: $0) }
        radioPosition = defaults.data(forKey: "radioPosition").flatMap { try? JSONDecoder().decode(Position.self, from: $0) }
        network = defaults.string(forKey: "network")
        blockList = defaults.data(forKey: "blocked").flatMap { try? JSONDecoder().decode(BlockList.self, from: $0) } ?? BlockList()
        var profiles = defaults.data(forKey: "radioProfiles").flatMap { try? JSONDecoder().decode(RadioProfileStore.self, from: $0) } ?? RadioProfileStore()
        if !profiles.seeded {
            profiles.seedIfNeeded()
            defaults.set(try? JSONEncoder().encode(profiles), forKey: "radioProfiles")
        }
        radioProfiles = profiles
        recentRadios = defaults.data(forKey: "recentRadios").flatMap { try? JSONDecoder().decode([SavedRadio].self, from: $0) } ?? []
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        lockScreenStatus = defaults.object(forKey: "lockScreenStatus") as? Bool ?? true
        keepRunningInBackground = defaults.object(forKey: "keepRunningInBackground") as? Bool ?? true
        let starring = defaults.object(forKey: "starWhatYouUse") as? Bool ?? true
        starWhatYouUse = starring
        Task { await engine.setStarWhatYouUse(starring) }
        locationChoice = defaults.string(forKey: "locationSource").flatMap(LocationSource.init(rawValue:))
        notificationSettings = defaults.data(forKey: "notifications").flatMap { try? JSONDecoder().decode(NotificationSettings.self, from: $0) } ?? NotificationSettings()
        reloadStored()
        Task { await follow() }
    }

    /// The app's own model, with its database on disk.
    public static func live() throws -> AppModel { AppModel(engine: MeshEngine(store: try .onDisk())) }

    /// Trying MeshChat without a radio: the demo's simulated radio and made-up mesh (DemoMesh), with its own
    /// history in memory and its own settings, so nothing of yours is read, changed or kept.
    public static func demo() -> AppModel {
        let suite = "io.github.sewci0.meshchat.demo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = (try? Store.inMemory()) ?? (try! Store.inMemory())
        DemoMesh.seed(store)
        let m = AppModel(engine: MeshEngine(store: store), defaults: defaults)
        m.isDemo = true
        m.home = DemoMesh.home
        m.savedRadio = .demo
        // for the App Store screenshots: `-demoScreen <name>` opens on a screen, and route, reach and
        // networks also show one thing there by themselves (a message's route, a reach check, the networks)
        let screen = UserDefaults.standard.string(forKey: "demoScreen")
        switch screen {
        case "channel", "route": m.open(.channel(0))
        case "map": m.tab = .map
        case "repeaters", "reach": m.tab = .repeaters
        case "nodes": m.tab = .nodes
        case "settings", "networks": m.tab = .settings
        default: break
        }
        if ["route", "reach", "networks"].contains(screen) { m.demoShow = screen }
        Task { await m.connect(.demo) }
        return m
    }

    /// Showing the demo (DemoMesh), not your radio.
    public private(set) var isDemo = false
    /// the demo's screenshot mode: something to show once by itself ("route", "reach" or "networks")
    public var demoShow: String?

    public var isConnected: Bool { if case .connected = connection { true } else { false } }

    /// Makes the link to a saved radio (tests put a simulated radio here).
    public var makeTransport: @MainActor (SavedRadio) -> MeshTransport = { $0.transport() }
    /// The first wait before reconnecting after a drop; it doubles each time, up to 30 s.
    public var retryBase: Duration = .seconds(2)
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    /// you disconnected: no reconnecting by itself until you connect again
    public private(set) var disconnectedByYou = false

    public func connect(_ radio: SavedRadio) async {
        savedRadio = radio
        recentRadios = [radio] + recentRadios.filter { $0.key != radio.key }.prefix(4)
        retries = 0
        disconnectedByYou = false
        await engine.connect(makeTransport(radio))
    }

    /// Disconnects and stays disconnected (no retries, not on return to the app) until you connect again.
    public func disconnect() async {
        disconnectedByYou = true
        retryTask?.cancel(); retryTask = nil
        await engine.disconnect()
    }

    /// Reconnects to the saved radio (on launch, coming back to the foreground, after a drop). `force`:
    /// you asked, even after disconnecting.
    public func reconnect(force: Bool = false) async {
        guard let r = savedRadio, force || !disconnectedByYou else { return }
        if force { disconnectedByYou = false }
        retryTask?.cancel(); retryTask = nil
        switch connection {
        case .connected, .connecting: return
        default: await engine.connect(makeTransport(r))
        }
    }

    public func forgetRadio() async {
        savedRadio = nil
        retryTask?.cancel(); retryTask = nil
        await engine.disconnect()
    }

    /// The link dropped or couldn't be made (the radio restarted, went out of range, WiFi changed): try
    /// again after 2, 4, 8, 16, then every 30 seconds.
    private func scheduleReconnect() {
        guard savedRadio != nil, autoReconnect, !disconnectedByYou, retryTask == nil else { return }
        retries += 1
        let wait = min(retryBase * (1 << min(retries - 1, 5)), .seconds(30))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.reconnect()
        }
    }

    // MARK: following the engine

    private func follow() async {
        for await u in engine.updates {
            switch u {
            case .connection(let s):
                connection = s
                switch s {
                case .connected:
                    retries = 0
                    retryTask?.cancel(); retryTask = nil
                    await pullRadio()
                case .failed, .disconnected:
                    battery = nil; batteryAt = .distantPast
                    scheduleReconnect()
                case .connecting: break
                }
            case .radio, .channels: await pullRadio()
            case .contacts:
                contacts = await engine.contacts
                // room again (after tidying, or making room): the notice has done its job
                if let max = device?.maxContacts, contacts.count < max * 95 / 100 { contactsFullNotice = false }
            case .contactsFull: contactsFullNotice = true
            case .messages(let c):
                messageVersion[c, default: 0] += 1
                reloadConversations()
            case .incoming(let m, let backlog): if !blockList.hides(m) { onIncoming?(m, backlog) }
            case .packets:
                packetVersion += 1
                if packetVersion % 10 == 1 { reloadHeard() }   // adverts change it; no need on every packet
            case .rooms: reloadRooms()
            case .routes: routeVersion += 1
            case .live: routeVersion += 1
            case .console(let k): consoles[k] = await engine.consoles[k] ?? []
            }
        }
    }

    /// Reads everything first, then updates at once, so no screen sees a half-updated radio.
    private func pullRadio() async {
        let s = await engine.snapshot
        me = s.me; device = s.device; channels = s.channels; contacts = s.contacts
        if let me = s.me { radioPosition = me.position; network = NetworkKey(me.radio).key }
        listened = (try? store.listened()) ?? []
    }

    public func reloadHeard() { heardByNetwork = HeardByNetwork((try? store.heardEverywhere()) ?? [], network: network) }

    // MARK: tidying contacts

    /// The radio heard a new node but its contact list is full, and it isn't making room: shown in Nodes
    /// until dismissed, or there's room again.
    public var contactsFullNotice = false

    /// Star contacts you use (people you message, rooms you join, repeaters you log in to as admin), so the
    /// radio never drops them when it makes room. On unless turned off.
    public var starWhatYouUse: Bool {
        didSet {
            defaults.set(starWhatYouUse, forKey: "starWhatYouUse")
            let engine = engine, on = starWhatYouUse
            Task { await engine.setStarWhatYouUse(on) }
        }
    }

    /// Every contact on the radio, or all but favourites, longest unheard first: for clearing the list.
    public func allContacts(keepFavourites: Bool) -> [Contact] {
        // (heard on any network: one heard on another lately isn't gone)
        ContactTidy.everything(Array(contacts.values),
                               lastHeard: Dictionary(heardByNetwork.anywhere.map { ($0.key, $0.lastHeard) }, uniquingKeysWith: { a, _ in a }),
                               keepFavourites: keepFavourites)
    }

    /// Has the radio make room for new nodes by itself (replacing the longest unheard that isn't a favourite).
    public func makeRoomWhenFull() async throws {
        var a = try await engine.autoAdd()
        a.flags |= AutoAddConfig.overwriteOldest
        try await engine.setAutoAdd(a)
        contactsFullNotice = false
    }

    /// What tidying the radio's contacts this way would remove and keep. Kept always: favourites, rooms
    /// you've joined, anyone you have messages with, and `yourRepeater`.
    public func contactTidy(_ options: ContactTidy.Options, yourRepeater: String?) -> ContactTidy {
        var messaged = Set<String>()
        for c in conversations.keys { if case .direct(let k) = c { messaged.insert(k.hex) } }
        // how far: its last advert's path, else the route the radio keeps for it
        var hops: [String: Int] = [:]
        for c in contacts.values { if let p = c.outPath { hops[c.key.hex] = p.hops.count } }
        // (heard on any network, as last heard: one heard on another lately isn't gone)
        let heard = heardByNetwork.anywhere
        for h in heard { hops[h.key] = h.hops }
        return ContactTidy(contacts: Array(contacts.values),
                           lastHeard: Dictionary(heard.map { ($0.key, $0.lastHeard) }, uniquingKeysWith: { a, _ in a }), hops: hops,
                           messaged: messaged, joinedRooms: Set(rooms.values.filter { !$0.left }.map(\.key)),
                           yourRepeater: yourRepeater, options: options)
    }

    /// Asks the radio for its battery, unless it was asked less than `maxAge` seconds ago (Settings and
    /// the Radio screen share the answer).
    public func refreshBattery(maxAge: TimeInterval = 60) async {
        guard isConnected, Date.now.timeIntervalSince(batteryAt) >= maxAge else { return }
        batteryAt = .now
        if let b = try? await engine.battery() { battery = b }
    }

    private func reloadStored() {
        reloadHeard()
        reloadConversations()
        reloadRooms()
        listened = (try? store.listened()) ?? []
    }

    private func reloadConversations() {
        conversations = Dictionary(((try? store.conversations()) ?? []).map { ($0.conversation, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func reloadRooms() {
        rooms = Dictionary(((try? store.rooms()) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: what the chat list needs

    public func title(of c: ConversationID) -> String {
        switch c {
        case .channel(let i): channels.first { $0.index == i }?.name ?? String(localized: "Channel \(i)")
        case .listened(let n): n
        case .direct(let k): contacts[k]?.name ?? String(k.hex.prefix(8))
        }
    }

    public func isUnread(_ c: ConversationID) -> Bool {
        guard let last = conversations[c]?.lastID else { return false }
        return last > (lastRead[c.description] ?? 0)
    }

    public func markRead(_ c: ConversationID) {
        if let last = conversations[c]?.lastID, (lastRead[c.description] ?? 0) < last { lastRead[c.description] = last }
        onRead?(c)
    }

    /// Read up to one message (from a notification's Mark as read: not anything newer that came since).
    public func markRead(_ c: ConversationID, upTo id: Int64) {
        if (lastRead[c.description] ?? 0) < id { lastRead[c.description] = id }
        onRead?(c)
    }

    public func isRoom(_ c: ConversationID) -> Bool {
        if case .direct(let k) = c { return contacts[k]?.type == .room }
        return false
    }

    /// Rooms joined here (not left) or with posts, newest first.
    public var roomList: [ConversationID] {
        var keys = Set(rooms.values.filter { !$0.left }.map(\.key))
        for c in conversations.keys { if case .direct(let k) = c, contacts[k]?.type == .room, rooms[k.hex]?.left != true { keys.insert(k.hex) } }
        return keys.compactMap { PublicKey(hex: $0) }.map { ConversationID.direct($0) }.sorted { latest($0) > latest($1) }
    }

    /// Takes a conversation off the chat list. A channel is left on the radio (freeing its slot) and its
    /// messages deleted, or the next channel in that slot would inherit them; a listened channel stops;
    /// a DM's messages go (the contact stays, and the other side keeps theirs); a room is left, its posts
    /// deleted too unless `keepingPosts`.
    public func delete(_ c: ConversationID, keepingPosts: Bool = false) async throws {
        switch c {
        case .channel(let i):
            try await engine.leaveChannel(i)
            try await engine.deleteConversation(c)
        case .listened(let name):
            try await engine.stopListening(to: name)
            try await engine.deleteConversation(c)
        case .direct(let k):
            if isRoom(c) { try await engine.leaveRoom(k) }
            if !isRoom(c) || !keepingPosts { try await engine.deleteConversation(c) }
        }
        if !(isRoom(c) && keepingPosts) { lastRead[c.description] = nil }
        notificationSettings.forget(c)   // a channel's slot goes to the next channel joined
        onRead?(c)
        if openConversation == c { openConversation = nil }
    }

    /// People with a conversation, newest first.
    public var directList: [ConversationID] {
        conversations.keys.filter { if case .direct = $0 { !isRoom($0) && !blockList.hides($0) } else { false } }.sorted { latest($0) > latest($1) }
    }

    func latest(_ c: ConversationID) -> Date { conversations[c]?.lastDate ?? .distantPast }
}
