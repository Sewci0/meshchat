import MeshChatCore
import SwiftUI

/// The app: chats, map, repeaters, nodes and settings; the connect screen until a radio is chosen.
public struct RootView: View {
    @State private var model: AppModel
    private let maps: (any MapProvider)?
    @Environment(\.scenePhase) private var phase

    public init(model: AppModel, maps: (any MapProvider)? = nil) {
        _model = State(initialValue: model)
        self.maps = maps
    }

    public var body: some View {
        TabView(selection: $model.tab) {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppModel.Tab.chats)
                .badge(model.unreadCount)
            MapTab(provider: maps)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppModel.Tab.map)
            RepeatersView()
                .tabItem { Label("Repeaters", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppModel.Tab.repeaters)
            NodesView()
                .tabItem { Label("Nodes", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppModel.Tab.nodes)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .modifier(PhoneLocationFollower())   // the phone's GPS as the node's position, when chosen
        .environment(model)
        .sheet(isPresented: .constant(model.savedRadio == nil)) {
            ConnectView().environment(model).interactiveDismissDisabled()
        }
        .task { await model.reconnect() }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await model.reconnect() } }   // WiFi links don't survive the background
        }
        .onOpenURL { url in
            // meshcore:// links from other apps or the camera: add the contact or join the channel
            if MeshLink(url.absoluteString) != nil { model.pendingLink = url.absoluteString; model.tab = .chats }
        }
    }
}

/// Only when something's wrong: the connection state and a way to try again, as a row at the top of
/// a list. Connected, it takes no room at all.
struct ConnectionNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.savedRadio != nil, !model.isConnected {
            HStack {
                ConnectionBadge().font(.subheadline).lineLimit(2)
                Spacer(minLength: 8)
                if case .connecting = model.connection {
                    ProgressView()
                } else {
                    Button("Reconnect") { Task { await model.reconnect(force: true) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The connection state as a small line for toolbars and lists.
struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected(let label): Label(label, systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .connecting(let label): Label("Connecting to \(label)…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .disconnected: Label("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// A tab's own screen: its large title on the same line as its toolbar buttons, not under them.
    func tabTitle(_ title: LocalizedStringKey) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        navigationTitle(title).toolbarTitleDisplayMode(.inlineLarge)
        #else
        navigationTitle(title)
        #endif
    }
}

extension Binding where Value == Bool {
    /// True while `item` holds something; setting false clears it (for alerts and dialogs about an optional).
    static func present<T: Sendable>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
