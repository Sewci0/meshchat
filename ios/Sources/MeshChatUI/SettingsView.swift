import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Settings: your node at the top (name, adverts, QR code), then the radio (how it's reached, the network
/// it's on, the device itself), where you are (shared on the mesh, and home on this iPhone), the app,
/// and troubleshooting. Every row stays put offline; the screens behind them say what needs the radio.
struct SettingsView: View {
    static let privacyPolicy = URL(string: "https://gist.github.com/Sewci0/c2a751f4ab9d0f8ca3b5b64f1100e24f")!
    /// "1.0 (3)"
    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "–") (\(i?["CFBundleVersion"] as? String ?? "–"))"
    }

    @Environment(AppModel.self) private var model
    @Environment(DemoSwitch.self) private var demo: DemoSwitch?

    var body: some View {
        NavigationStack {
            Form {
                if model.isDemo, let demo {
                    Section {
                        Label("You're trying MeshChat with a simulated radio", systemImage: "play.circle")
                        Button("Leave the demo") { demo.leave() }
                    } footer: {
                        Text("Everything here is made up. Leaving the demo takes you back to connecting your own radio.")
                    }
                }
                Section {
                    NavigationLink { NodeIdentityView() } label: { NodeHeader() }
                    ConnectionNotice()
                }
                Section("Radio") {
                    // how it's reached; whether it's up is on the card above (and the notice under it)
                    NavigationLink { ConnectionSettingsView() } label: {
                        LabeledContent("Connection", value: model.savedRadio.map { $0.isBluetooth ? "Bluetooth" : "WiFi" } ?? String(localized: "None"))
                    }
                    NavigationLink { NetworkSettingsView() } label: {
                        LabeledContent("Network", value: model.me == nil ? "—" : model.currentProfile?.name ?? String(localized: "Custom"))
                    }
                    NavigationLink("Mesh behaviour") { MeshBehaviourView() }
                    NavigationLink { RadioDeviceView() } label: {
                        LabeledContent("About this radio", value: model.device?.version ?? "—")
                    }
                }
                Section {
                    NavigationLink { NodeLocationView() } label: {
                        LabeledContent("Position shared on the mesh", value: model.locationSource == .none ? String(localized: "Not shared") : model.locationSource.label)
                    }
                    NavigationLink { HomeLocationView() } label: {
                        LabeledContent("Home location", value: model.home == nil ? String(localized: "Not set") : String(localized: "home.set", defaultValue: "Set", comment: "Settings: the home location has been set"))
                    }
                } header: { Text("Location") } footer: {
                    Text("Your shared position goes out in your adverts and anyone on the mesh can read it. Home stays on this iPhone and is only used for distances and the map.")
                }
                Section("App") {
                    NavigationLink { NotificationSettingsView() } label: {
                        LabeledContent("Notifications", value: notificationSummary)
                    }
                    NavigationLink { BlockedView() } label: {
                        LabeledContent("Blocked", value: model.blockList.entries.isEmpty ? String(localized: "None") : "\(model.blockList.entries.count)")
                    }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                    Link(destination: Self.privacyPolicy) { Label("Privacy policy", systemImage: "hand.raised.square") }
                    NavigationLink { AcknowledgementsView() } label: { Label("Acknowledgements", systemImage: "heart.text.square") }
                } header: {
                    Text("About MeshChat")
                }
                Section {
                    NavigationLink("Packet log") { PacketsView() }
                } header: { Text("Troubleshooting") } footer: {
                    Text("MeshChat keeps its history on this iPhone and needs no internet: everything comes from your radio. Only map tiles you haven't kept offline are fetched online.")
                }
            }
            .formStyle(.grouped)
            .tabTitle("Settings")
            // a notification's "Notification settings" action lands here
            .navigationDestination(isPresented: Binding(get: { model.showNotificationSettings }, set: { model.showNotificationSettings = $0 })) {
                NotificationSettingsView()
            }
            .navigationDestination(isPresented: Binding(get: { model.demoShow == "networks" }, set: { if !$0 { model.demoShow = nil } })) {
                NetworkSettingsView()
            }
            .task(id: model.isConnected) { await model.refreshBattery() }
        }
    }

    private var notificationSummary: String {
        if model.notificationPermission == .denied { return String(localized: "Off in iOS") }
        return model.notificationSettings.enabled ? String(localized: "On") : String(localized: "Off")
    }
}

/// The top of Settings: your node's name, the radio it runs on and how it's reached, and the battery.
private struct NodeHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.me?.name ?? String(localized: "Your node")).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let v = battery {
                Text(v).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Battery \(v)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "Heltec V3 · Bluetooth", or "… · Connecting…" / "… · Not connected"
    private var subtitle: String {
        guard let r = model.savedRadio else { return String(localized: "No radio") }
        let state = switch model.connection {
        case .connected: r.isBluetooth ? "Bluetooth" : "WiFi"
        case .connecting: String(localized: "Connecting…")
        case .failed, .disconnected: String(localized: "Not connected")
        }
        return "\(r.title) · \(state)"
    }

    private var battery: String? {
        model.battery.flatMap { $0.millivolts > 0 ? String(format: "%.2f V", Double($0.millivolts) / 1000) : nil }
    }
}

/// `ConnectionNotice` as a form's first section: there only while the radio isn't connected, so it
/// explains the greyed-out buttons below and offers to reconnect.
struct ConnectionNoticeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.savedRadio != nil, !model.isConnected { Section { ConnectionNotice() } }
    }
}

/// Settings › Your node: the name others see, your QR code, and announcing yourself with an advert.
struct NodeIdentityView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    /// the radio's name as last copied into the field (an edit in progress isn't overwritten)
    @State private var seeded: String?
    @State private var confirmAdvert = false
    @State private var showCode = false
    @State private var message: String?

    var body: some View {
        Form {
            ConnectionNoticeSection()
            Section {
                TextField("Public name", text: $name)
                    .autocorrectionDisabled()
                    .onSubmit(saveName)
                if name.utf8.count > 31 { Text("Too long: names fit in 31 bytes.").font(.caption).foregroundStyle(.red) }
                Button("Save name", action: saveName)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == model.me?.name || name.utf8.count > 31 || !model.isConnected)
            } header: { Text("Name") } footer: {
                Text("Up to 31 bytes. Others see a new name after you next announce to the whole mesh.")
            }
            Section("Share") {
                // (a Label button doesn't grey out by itself when disabled)
                Button { showCode = true } label: { Label("Show my QR code", systemImage: "qrcode").opacity(model.me == nil ? 0.4 : 1) }
                    .disabled(model.me == nil)
            }
            Section {
                Button("Announce nearby") { run(String(localized: "Announced to the radios that hear you directly.")) { try await model.engine.sendAdvert(flood: false) } }
                    .disabled(!model.isConnected)
                Button("Announce to the whole mesh…") { confirmAdvert = true }
                    .disabled(!model.isConnected)
            } header: { Text("Announce yourself") } footer: {
                Text(sharesPosition
                     ? "An advert tells other radios your name, key and position so they can message you. Nearby reaches only radios that hear you directly (zero-hop). The whole mesh is passed on by every repeater (flood): use it after setup or a rename, not routinely."
                     : "An advert tells other radios your name and key so they can message you. Nearby reaches only radios that hear you directly (zero-hop). The whole mesh is passed on by every repeater (flood): use it after setup or a rename, not routinely.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Your node")
        .onAppear(perform: seed)
        .onChange(of: model.me?.name) { seed() }
        .confirmationDialog("Announce “\(model.me?.name ?? name)” to the whole mesh?", isPresented: $confirmAdvert, titleVisibility: .visible) {
            Button("Announce") { run(String(localized: "Announced to the whole mesh.")) { try await model.engine.sendAdvert(flood: true) } }
        } message: {
            Text(floodMessage)
        }
        .sheet(isPresented: $showCode) { ContactCodesView() }
        .alert(message ?? "", isPresented: .present($message)) { Button("OK") {} }
    }

    /// whether adverts carry a position, as the radio says
    private var sharesPosition: Bool { (model.me?.advertLocationPolicy ?? 0) != 0 }

    /// What a flood advert gives away, from the radio's own setting.
    private var floodMessage: String {
        let start = String(localized: "Every repeater in the region passes it on, so others can find you and message you.")
        guard let me = model.me, me.advertLocationPolicy != 0 else {
            return start + " " + String(localized: "It shares your name and key. Your position is not included.")
        }
        let shares = me.position.map { String(localized: "It shares your name, key and your position (\(NodeLocationView.format($0))), which anyone on the mesh can read.") }
            ?? String(localized: "It shares your name, key and the position stored on the radio, which anyone on the mesh can read.")
        return start + " " + shares + " " + String(localized: "Change this in Settings › Position shared on the mesh.")
    }

    /// Copies the radio's name into the field, unless you've started changing it.
    private func seed() {
        let current = model.me?.name ?? ""
        if name.isEmpty || name == seeded { name = current }
        seeded = current
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.utf8.count <= 31, n != model.me?.name, model.isConnected else { return }
        run(String(localized: "Name saved. Others see it after you next announce to the whole mesh.")) { try await model.engine.rename(n) }
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); message = done } catch { message = "\(error)" }
        }
    }
}

/// The people you've blocked, to unblock.
struct BlockedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.blockList.entries) { e in
                    Label(e.name, systemImage: "hand.raised")
                        .swipeActions { Button("Unblock") { model.unblock(e) }.tint(.blue) }
                }
            } footer: {
                Text("Their messages are hidden on this iPhone and don't notify you. They aren't told, and their messages still reach others on the mesh. Swipe to unblock. To block someone, touch and hold one of their messages, or use their page in Nodes.")
            }
        }
        .overlay {
            if model.blockList.entries.isEmpty {
                ContentUnavailableView("No one blocked", systemImage: "hand.raised",
                                       description: Text("To block someone, touch and hold one of their messages, or use their page in Nodes."))
            }
        }
        .navigationTitle("Blocked")
    }
}
