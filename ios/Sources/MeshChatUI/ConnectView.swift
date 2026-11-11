import MeshChatCore
import MeshCoreKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Choosing a radio when there's none yet: nearby Bluetooth radios (strongest first), or a WiFi address,
/// or trying the app with the demo's simulated radio.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(DemoSwitch.self) private var demo: DemoSwitch?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                RadioPicker { dismiss() }
                if case .failed(let why) = model.connection {
                    Section { Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let demo {
                    Section {
                        Button { demo.start() } label: { Label("Try without a radio", systemImage: "play.circle") }
                    } footer: {
                        Text("A simulated radio on a made-up mesh, so you can look around. Nothing is sent, and nothing is kept.")
                    }
                }
            }
            .navigationTitle("Connect a radio")
        }
    }
}

/// The ways to reach a radio, as form sections: Bluetooth radios nearby (scanned while shown), and a
/// WiFi address. `link` shows just one of them.
struct RadioPicker: View {
    enum Link: String, CaseIterable, Identifiable {
        case bluetooth = "Bluetooth", wifi = "WiFi"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    var link: Link?
    /// after a connection is made
    var connected: () -> Void = {}
    @State private var radios: [UUID: DiscoveredRadio] = [:]
    @State private var host = ""
    @State private var port = "5000"
    /// the address last connected to over WiFi, filled in next time
    @AppStorage("lastWiFiHost") private var lastHost = ""
    @AppStorage("lastWiFiPort") private var lastPort = 5000
    @FocusState private var typing: Bool
    @State private var connecting = false
    @State private var bluetooth: BluetoothAvailability = .starting

    var body: some View {
        if link != .wifi { bluetoothSection.task { await scan() } }
        if link != .bluetooth { wifiSection }
    }

    private var bluetoothSection: some View {
        Section {
            switch bluetooth {
            case .unsupported:
                Label("Bluetooth isn't available on this device. Connect over WiFi.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
            case .off:
                Label("Bluetooth is off. Turn it on in Control Center or Settings.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
            case .notAllowed:
                Label("MeshChat isn't allowed to use Bluetooth.", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Button("Allow in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            case .starting, .on:
                if radios.isEmpty {
                    HStack { ProgressView(); Text("Looking for radios…").foregroundStyle(.secondary) }
                }
            }
            ForEach(radios.values.sorted { $0.rssi > $1.rssi }) { r in
                Button { Task { await connect(.bluetooth(id: r.id, name: r.name)) } } label: {
                    LabeledContent {
                        SignalLabel(rssi: r.rssi)
                    } label: {
                        Label(r.name, systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(connecting)
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            if bluetooth == .on || bluetooth == .starting {
                Text("Radios with Bluetooth companion firmware. The first time, iOS asks for the radio's PIN (shown on its screen, or 123456). A radio connected to another phone doesn't show up here.")
            }
        }
    }

    private var wifiSection: some View {
        Section {
            TextField("Address, e.g. meshcore.local or 192.168.1.50", text: $host)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused($typing)
                .submitLabel(.go)
                .onSubmit(connectWiFi)
            TextField("Port", text: $port)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($typing)
            Button(action: connectWiFi) {
                if connecting { HStack { ProgressView(); Text("Connecting…") } } else { Text("Connect over WiFi") }
            }
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
        } header: {
            Text("WiFi")
        } footer: {
            Text("For radios with WiFi companion firmware (port 5000). The radio serves one WiFi app at a time: connecting takes over from the previous one.")
        }
        .onAppear {
            guard host.isEmpty else { return }
            // the radio in use, else the address last typed here, else the newest WiFi radio used
            if case .wifi(let h, let p) = model.savedRadio { host = h; port = String(p) }
            else if !lastHost.isEmpty { host = lastHost; port = String(lastPort) }
            else if let r = model.recentRadios.first(where: { if case .wifi = $0 { true } else { false } }), case .wifi(let h, let p) = r {
                host = h; port = String(p)
            }
        }
    }

    private func connectWiFi() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !connecting else { return }
        typing = false   // the keyboard goes: the connection's progress shows below it
        let p = UInt16(port) ?? 5000
        lastHost = h; lastPort = Int(p)
        Task { await connect(.wifi(host: h, port: p)) }
    }

    private func scan() async {
        let scanner = BluetoothScanner()
        defer { scanner.stop() }
        async let states: Void = follow(scanner.availability)
        for await r in scanner.radios { radios[r.id] = r }
        await states
    }

    private func follow(_ states: AsyncStream<BluetoothAvailability>) async {
        for await a in states { bluetooth = a }
    }

    private func connect(_ r: SavedRadio) async {
        connecting = true
        await model.connect(r)
        connecting = false
        if model.isConnected { connected() }
    }
}

/// Settings › Connection: the radio in use and its state in one row, then every other radio in one list
/// (recent ones, and Bluetooth radios in range, each once), WiFi addresses behind a row of their own, and
/// forgetting. Tapping another radio scrolls up to the first row, where its connecting shows; switching
/// away from a working link asks first. (Staying connected in the background over WiFi is in
/// Notifications, with the lock-screen status it serves.)
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false
    @State private var scan = RadioScan()
    /// a radio to switch to, asked about first while another is connected
    @State private var switching: SavedRadio?

    var body: some View {
        @Bindable var model = model
        let current = model.savedRadio
        let recent = model.recentRadios.filter { $0.key != current?.key }
        let recentKeys = Set(recent.map(\.key))
        // in range, not the one in use and not already listed as recent
        let nearby = scan.radios.values
            .map { (radio: SavedRadio.bluetooth(id: $0.id, name: $0.name), rssi: $0.rssi) }
            .filter { $0.radio.key != current?.key && !recentKeys.contains($0.radio.key) }
            .sorted { $0.rssi > $1.rssi }
        ScrollViewReader { proxy in
            Form {
                Section {
                    CurrentRadioRow()
                    if model.isConnected {
                        Button("Disconnect") { Task { await model.disconnect() } }
                    } else if case .connecting = model.connection {
                        Button("Stop trying") { Task { await model.disconnect() } }
                    } else if current != nil {
                        Button("Reconnect") { Task { await model.reconnect(force: true) } }
                    }
                    if current != nil { Toggle("Reconnect automatically", isOn: $model.autoReconnect) }
                } header: {
                    Text("This radio").id(Self.top)
                } footer: {
                    Text((model.disconnectedByYou
                          ? String(localized: "You disconnected: MeshChat stays off the radio until you reconnect.")
                          : String(localized: "Reconnects by itself when the link drops: the radio restarted, went out of range, or WiFi changed."))
                         + (current?.isBluetooth == false ? " " + String(localized: "To keep receiving in the background over WiFi, see Notifications.") : ""))
                }

                Section {
                    ForEach(recent, id: \.key) { r in
                        otherRow(r, rssi: rssi(of: r), proxy: proxy)
                            .swipeActions { Button("Forget", role: .destructive) { model.forget(r) } }
                    }
                    ForEach(nearby, id: \.radio.key) { n in otherRow(n.radio, rssi: n.rssi, proxy: proxy) }
                    bluetoothState(empty: nearby.isEmpty)
                    NavigationLink { WiFiRadioView() } label: { Label("Add a WiFi radio…", systemImage: "wifi") }
                } header: {
                    Text("Other radios")
                } footer: {
                    Text("Tap one to switch to it; swipe a recent one to forget it. Bluetooth radios show while in range (not one connected to another phone); the first time, iOS asks for the radio's PIN, shown on its screen or 123456.")
                }

                if current != nil { BluetoothPinSection() }

                if current != nil {
                    Section {
                        Button("Forget this radio…", role: .destructive) { confirmForget = true }
                            .confirmationDialog("Forget \(current?.title ?? String(localized: "this radio"))?", isPresented: $confirmForget, titleVisibility: .visible) {
                                Button("Forget", role: .destructive) {
                                    if let r = model.savedRadio { model.forget(r) }
                                    Task { await model.forgetRadio() }
                                }
                            } message: {
                                Text("MeshChat disconnects and asks which radio to use. Messages already on this iPhone stay.")
                            }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connection")
            .task { await scan.run() }
            .confirmationDialog("Switch to \(switching?.title ?? String(localized: "this radio"))?", isPresented: .present($switching), titleVisibility: .visible) {
                Button("Switch") { if let r = switching { go(r, proxy) } }
            } message: {
                if let title = current?.title { Text("MeshChat disconnects from \(title) and connects to this one.") }
                else { Text("MeshChat disconnects from the radio in use and connects to this one.") }
            }
        }
    }

    private static let top = "current radio"

    /// A recent or nearby radio: its name, how it's reached, and its signal while in range.
    private func otherRow(_ r: SavedRadio, rssi: Int?, proxy: ScrollViewProxy) -> some View {
        Button { choose(r, proxy) } label: {
            LabeledContent {
                if let rssi { SignalLabel(rssi: rssi) }
                else if r.isBluetooth, scan.availability == .on { Text("Not in range").font(.caption).foregroundStyle(.secondary) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        // (plain colours: a button's tint would make the name look like a link)
                        Text(r.title).foregroundStyle(Color.primary)
                        Text(r.linkName).font(.caption).foregroundStyle(Color.secondary)
                    }
                } icon: { Image(systemName: r.isBluetooth ? "antenna.radiowaves.left.and.right" : "wifi") }
            }
        }
        // (not locked while connecting: switching away from a radio that won't answer is when it's needed)
    }

    @ViewBuilder private func bluetoothState(empty: Bool) -> some View {
        switch scan.availability {
        case .unsupported:
            Label("Bluetooth isn't available on this device.", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
        case .off:
            Label("Bluetooth is off: turn it on in Control Center or Settings to see radios nearby.", systemImage: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
        case .notAllowed:
            Label("MeshChat isn't allowed to use Bluetooth.", systemImage: "hand.raised").foregroundStyle(.secondary)
            #if os(iOS)
            Button("Allow in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
        case .starting, .on:
            if empty { HStack { ProgressView(); Text("Looking for Bluetooth radios…").foregroundStyle(.secondary) } }
        }
    }

    private func rssi(of r: SavedRadio) -> Int? {
        if case .bluetooth(let id, _) = r { return scan.radios[id]?.rssi }
        return nil
    }

    /// Switching away from a working link asks first; otherwise it goes straight away.
    private func choose(_ r: SavedRadio, _ proxy: ScrollViewProxy) {
        if model.isConnected, model.savedRadio?.key != r.key { switching = r } else { go(r, proxy) }
    }

    /// Up to the first row, where the connecting shows, and connect.
    private func go(_ r: SavedRadio, _ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
        Task { await model.connect(r) }
    }
}

/// The radio in use, how it's reached and its state, in one row: "Alpha · Bluetooth · Connected".
struct CurrentRadioRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let r = model.savedRadio {
            let (state, symbol, colour): (String, String, Color) = switch model.connection {
            case .connected: (String(localized: "Connected"), "dot.radiowaves.left.and.right", .green)
            case .connecting: (String(localized: "Connecting…"), "hourglass", .secondary)
            case .failed: (String(localized: "Couldn't connect"), "exclamationmark.triangle", .orange)
            case .disconnected: (String(localized: "Not connected"), "antenna.radiowaves.left.and.right.slash", .secondary)
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.headline)
                    Text(r.linkName + " · " + state).font(.subheadline).foregroundStyle(colour)
                    if case .failed(let why) = model.connection {
                        // the state above already says it couldn't connect (the prefix as TransportError words it,
                        // in the same language)
                        let prefix = String(localized: "Couldn't connect: \(String())")
                        Text(why.hasPrefix(prefix) ? String(why.dropFirst(prefix.count)) : why).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                if case .connecting = model.connection { ProgressView() } else { Image(systemName: symbol).foregroundStyle(colour) }
            }
            .accessibilityElement(children: .combine)
        } else {
            Label("No radio yet: pick one below", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
        }
    }
}

/// Connecting to a radio over WiFi: its address (the last one used is filled in). Why it couldn't connect
/// shows once you've tried from here, not the radio in use's earlier failure.
struct WiFiRadioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tried = false

    var body: some View {
        Form {
            RadioPicker(link: .wifi) { dismiss() }
            if tried, case .failed(let why) = model.connection {
                Section { Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .onChange(of: model.connection) { _, state in
            if case .connecting = state { tried = true }
            // done once the radio tried from here is up (connecting can return before it is)
            if tried, case .connected = state { dismiss() }
        }
        .formStyle(.grouped)
        .navigationTitle("WiFi radio")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Bluetooth radios in range, scanned while a screen shows them, and whether Bluetooth can be used.
@MainActor @Observable
final class RadioScan {
    var radios: [UUID: DiscoveredRadio] = [:]
    var availability: BluetoothAvailability = .starting

    func run() async {
        let scanner = BluetoothScanner()
        defer { scanner.stop() }
        async let states: Void = follow(scanner.availability)
        for await r in scanner.radios { radios[r.id] = r }
        await states
    }

    private func follow(_ states: AsyncStream<BluetoothAvailability>) async {
        for await a in states { availability = a }
    }
}

extension SavedRadio {
    public var isBluetooth: Bool { if case .bluetooth = self { true } else { false } }

    /// How it's reached, under its name (a WiFi radio's name is its address): "Bluetooth", "WiFi", or
    /// "WiFi · port 5001" when not the usual port.
    public var linkName: String {
        switch self {
        case .bluetooth: String(localized: "Bluetooth")
        case .wifi(_, let port): port == 5000 ? String(localized: "WiFi") : String(localized: "WiFi · port \(port)")
        case .demo: String(localized: "Simulated")
        }
    }
}

/// Signal strength as bars plus the number (colour is never the only signal).
struct SignalLabel: View {
    let rssi: Int
    var body: some View {
        let bars = rssi > -60 ? 4 : rssi > -70 ? 3 : rssi > -80 ? 2 : 1
        HStack(spacing: 4) {
            Image(systemName: "cellularbars", variableValue: Double(bars) / 4)
            Text("\(rssi) dBm").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signal \(rssi) decibel-milliwatts")
    }
}
