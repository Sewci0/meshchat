import CoreLocation
import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Settings › Network: your saved networks (tap one to switch the radio to it), what the radio is on
/// now, its transmit power, and suggested networks to add. Every switch asks first.
struct NetworkSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var applying: RadioProfile?
    @State private var editing: ProfileDraft?
    @State private var deleting: RadioProfile?
    @State private var addingLink = false
    @State private var power = 22
    @State private var powerFrom: Int?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        let active = model.currentProfile
        Form {
            ConnectionNoticeSection()
            Section {
                ForEach(model.radioProfiles.profiles) { p in
                    Button { if active?.id != p.id { applying = p } } label: {
                        ProfileRow(profile: p, active: active?.id == p.id)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { deleting = p }
                        Button("Edit") { editing = ProfileDraft(profile: p, isNew: false) }.tint(.accentColor)
                    }
                    .swipeActions(edge: .leading) {
                        ShareLink(item: p.shareLink) { Label("Share", systemImage: "square.and.arrow.up") }.tint(.green)
                    }
                    .contextMenu { menu(for: p, active: active?.id == p.id) }
                }
                if model.radioProfiles.profiles.isEmpty {
                    Text("No saved networks. Save the radio's current settings, or add one below.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Your networks")
            } footer: {
                Text("Radios hear only others set the same: frequency, bandwidth, spreading factor and coding rate. Tap a network to switch the radio to it; swipe for more.")
            }

            Section {
                if let r = model.me?.radio {
                    LabeledContent("Network", value: active?.name ?? String(localized: "Custom"))
                    LabeledContent("Frequency", value: String(format: "%.3f MHz", r.frequencyMHz))
                    LabeledContent("Bandwidth", value: "\(r.bandwidthKHz.formatted()) kHz")
                    LabeledContent("Spreading factor", value: "SF\(r.spreadingFactor)")
                    LabeledContent("Coding rate", value: "4/\(r.codingRate)")
                    Button(active == nil ? "Save as a network…" : "Change settings…") {
                        editing = ProfileDraft(profile: RadioProfile(name: active == nil ? String(localized: "My network") : String(localized: "\(active!.name) (changed)"), radio: r), isNew: true)
                    }
                } else {
                    LabeledContent("Network", value: "—")
                }
            } header: {
                Text("On the radio now")
            } footer: {
                if model.me != nil, active == nil { Text("Not one of your saved networks.") }
            }

            Section {
                if let me = model.me {
                    Stepper(value: $power, in: -9...max(-9, me.maxTxPower)) {
                        LabeledContent("Transmit power", value: "\(power) dBm")
                    }
                    Button("Save transmit power") { run(String(localized: "Transmit power saved.")) { try await model.engine.setTxPower(power) } }
                        .disabled(power == me.txPower || !model.isConnected || busy)
                } else {
                    LabeledContent("Transmit power", value: "—")
                }
            } header: { Text("Transmit power") } footer: {
                if let me = model.me {
                    Text("Up to \(me.maxTxPower) dBm on this radio. Lower saves battery and is kinder to neighbours; keep within your country's limit (in the EU, 27 dBm ERP on 869.4–869.65 MHz).")
                }
            }

            let suggestions = model.radioProfiles.suggestions
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { p in
                        HStack {
                            ProfileRow(profile: p, active: false)
                            Button("Add") { model.radioProfiles.add(p) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                } header: { Text("Suggested networks") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let r = model.me?.radio {
                        Button { editing = ProfileDraft(profile: RadioProfile(name: String(localized: "My network"), radio: r), isNew: true) } label: {
                            Label("Save the radio's settings", systemImage: "square.and.arrow.down")
                        }
                    }
                    Button { editing = ProfileDraft(profile: RadioProfile(name: String(localized: "New network"), radio: model.me?.radio ?? RadioProfile.suggested[0].radio), isNew: true) } label: {
                        Label("New network", systemImage: "plus")
                    }
                    Button { addingLink = true } label: { Label("Add from a link or QR code", systemImage: "qrcode.viewfinder") }
                } label: { Label("Add network", systemImage: "plus") }
            }
        }
        .onAppear(perform: seedPower)
        .onChange(of: model.me?.txPower) { seedPower() }
        .sheet(item: $editing) { d in ProfileEditorView(draft: d) }
        .sheet(isPresented: $addingLink) { AddNetworkFromCodeView() }
        .confirmationDialog(applying.map { String(localized: "Switch to \($0.name)?") } ?? "", isPresented: .present($applying), titleVisibility: .visible) {
            Button("Switch") { if let p = applying { switchTo(p) } }
        } message: {
            if let p = applying { Text(switchWarning(to: p)) }
        }
        .confirmationDialog(deleting.map { String(localized: "Delete \($0.name)?") } ?? "", isPresented: .present($deleting), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let p = deleting { model.radioProfiles.remove(id: p.id) } }
        } message: { Text("Only the saved network goes; the radio stays as it is.") }
        .alert(message ?? "", isPresented: .present($message)) { Button("OK") {} }
    }

    @ViewBuilder private func menu(for p: RadioProfile, active: Bool) -> some View {
        if !active { Button { applying = p } label: { Label("Switch to it", systemImage: "dot.radiowaves.left.and.right") } }
        Button { editing = ProfileDraft(profile: p, isNew: false) } label: { Label("Edit", systemImage: "pencil") }
        Button { model.radioProfiles.duplicate(id: p.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        ShareLink(item: p.shareLink) { Label("Share", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
    }

    private func switchWarning(to p: RadioProfile) -> String {
        var s = model.currentProfile.map { String(localized: "The radio changes at once and keeps it after a restart. You'll stop hearing everyone on \($0.name) until you switch back. Contacts and channels are kept.") }
            ?? String(localized: "The radio changes at once and keeps it after a restart. You'll stop hearing everyone on its current settings until you switch back. Contacts and channels are kept.")
        if let tx = p.txPower { s += " " + String(localized: "Transmit power becomes \(tx) dBm.") }
        if let h = p.pathHashMode { s += " " + String(localized: "Path hashes become \(h + 1)-byte.") }
        return s
    }

    private func switchTo(_ p: RadioProfile) {
        guard model.isConnected else { message = String(localized: "Connect to the radio to switch it."); return }
        run(String(localized: "Switched to \(p.name).")) { try await model.engine.apply(p) }
    }

    /// The radio's power into the stepper, unless it's being changed.
    private func seedPower() {
        guard let tx = model.me?.txPower, powerFrom == nil || power == powerFrom else { return }
        power = tx
        powerFrom = tx
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); message = done } catch { message = "\(error)" }
        }
    }
}

/// A saved network in a list: its name, notes and settings, ticked when the radio is on it.
private struct ProfileRow: View {
    let profile: RadioProfile
    let active: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                if let n = profile.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(profile.radio.summary + (profile.txPower.map { " · \($0) dBm" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if active { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("On the radio now") }
        }
        .contentShape(.rect)
    }
}

/// A network being made or changed.
struct ProfileDraft: Identifiable {
    let id = UUID()
    var profile: RadioProfile
    var isNew: Bool
}

/// Making or changing a saved network: its name and notes, the LoRa settings, and optionally the
/// transmit power and path hash size to use on it. Can switch the radio to it on saving.
struct ProfileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile: RadioProfile
    private let isNew: Bool
    @State private var frequency: String
    @State private var setsPower: Bool
    @State private var power: Int
    @State private var setsHash: Bool
    @State private var hash: Int
    @State private var switchNow: Bool
    @State private var busy = false
    @State private var problem: String?

    init(draft: ProfileDraft) {
        var p = draft.profile
        // a bandwidth off by a float's rounding, onto the one it means
        if let near = RadioSettings.bandwidths.first(where: { abs($0 - p.radio.bandwidthKHz) < 0.05 }) { p.radio.bandwidthKHz = near }
        _profile = State(initialValue: p)
        isNew = draft.isNew
        _frequency = State(initialValue: RadioProfile.number(p.radio.frequencyMHz, decimals: 3))
        _setsPower = State(initialValue: p.txPower != nil)
        _power = State(initialValue: p.txPower ?? 22)
        _setsHash = State(initialValue: p.pathHashMode != nil)
        _hash = State(initialValue: p.pathHashMode ?? 0)
        _switchNow = State(initialValue: false)
    }

    private var isActive: Bool { !isNew && model.currentProfile?.id == profile.id }

    /// What's being saved: the fields as they are.
    private var result: RadioProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.notes = p.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let f = Double(frequency.replacingOccurrences(of: ",", with: ".")) { p.radio.frequencyMHz = f } else { p.radio.frequencyMHz = 0 }
        p.txPower = setsPower ? power : nil
        p.pathHashMode = setsHash ? hash : nil
        return p
    }

    private var radioChanged: Bool {
        guard let now = model.me?.radio else { return false }
        return !RadioProfile.sameNetwork(result.radio, now) || (result.txPower.map { $0 != model.me?.txPower } ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $profile.name)
                    TextField("Notes (optional)", text: Binding(get: { profile.notes ?? "" }, set: { profile.notes = $0 }), axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    LabeledContent("Frequency") {
                        HStack(spacing: 4) {
                            TextField("869.618", text: $frequency)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text("MHz").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Bandwidth", selection: $profile.radio.bandwidthKHz) {
                        ForEach(bandwidths, id: \.self) { Text("\($0.formatted()) kHz").tag($0) }
                    }
                    Picker("Spreading factor", selection: $profile.radio.spreadingFactor) {
                        ForEach(5...12, id: \.self) { Text("SF\($0)").tag($0) }
                    }
                    Picker("Coding rate", selection: $profile.radio.codingRate) {
                        ForEach(5...8, id: \.self) { Text("4/\($0)").tag($0) }
                    }
                } header: { Text("Radio") } footer: {
                    if let p = result.radio.problem { Text(p).foregroundStyle(.orange) }
                    else { Text("Everyone on the network uses the same four.") }
                }
                Section {
                    Toggle("Set transmit power", isOn: $setsPower)
                    if setsPower {
                        Stepper(value: $power, in: -9...max(-9, model.me?.maxTxPower ?? 22)) { LabeledContent("Transmit power", value: "\(power) dBm") }
                    }
                    Toggle("Set path hash size", isOn: $setsHash)
                    if setsHash {
                        Picker("Path hashes", selection: $hash) {
                            Text("1 byte").tag(0); Text("2 bytes").tag(1); Text("3 bytes").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Also, when switching to it") } footer: {
                    Text("Left off, the radio keeps its own.")
                }
                if model.isConnected, isNew || isActive {
                    Section {
                        Toggle(isNew ? "Switch the radio to it" : "Apply the changes to the radio", isOn: $switchNow)
                    } footer: {
                        if switchNow, radioChanged {
                            Text("The radio changes at once. You'll only hear nodes on these settings until you switch back.")
                        }
                    }
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New network" : "Edit network")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Save", action: save).disabled(result.name.isEmpty || !result.radio.isValid)
                    }
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    /// The bandwidths to pick from, with the profile's own if it's an odd one.
    private var bandwidths: [Double] {
        RadioSettings.bandwidths.contains(profile.radio.bandwidthKHz) ? RadioSettings.bandwidths
            : (RadioSettings.bandwidths + [profile.radio.bandwidthKHz]).sorted()
    }

    private func save() {
        var p = result
        if isNew { p = model.radioProfiles.add(p) } else { model.radioProfiles.update(p) }
        guard switchNow, model.isConnected else { dismiss(); return }
        busy = true
        Task {
            defer { busy = false }
            do { try await model.engine.apply(p); dismiss() } catch { problem = String(localized: "Saved, but not applied: \(String(describing: error))") }
        }
    }
}

/// Settings › About this radio: the device (model, firmware, battery, limits), its clock, restarting
/// it, and erasing it.
struct RadioDeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var clock: Date?
    @State private var confirmRestart = false
    @State private var confirmErase = false
    @State private var typingName = false
    @State private var typedName = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            ConnectionNoticeSection()
            if let d = model.device {
                Section {
                    LabeledContent("Model", value: d.model)
                    LabeledContent("Firmware", value: "\(d.version) (\(d.buildDate))")
                    if let b = model.battery, b.millivolts > 0 {
                        LabeledContent("Battery", value: String(format: "%.2f V", Double(b.millivolts) / 1000))
                    }
                    LabeledContent("Contacts", value: String(localized: "up to \(d.maxContacts)"))
                    LabeledContent("Channels", value: String(localized: "up to \(d.maxChannels)"))
                }
            } else {
                Section { Text("Connect to see this radio's details.").foregroundStyle(.secondary) }
            }

            Section {
                LabeledContent("Radio's clock") {
                    if let clock {
                        let off = clock.timeIntervalSinceNow
                        Text(abs(off) < 60 ? String(localized: "On time") : clock.formatted(date: .abbreviated, time: .shortened))
                    } else { Text("—") }
                }
                Button("Set from this iPhone") {
                    run(String(localized: "Clock set.")) { try await model.engine.syncClock(); clock = try? await model.engine.radioTime() }
                }
                .disabled(!model.isConnected || busy)
            } header: { Text("Clock") } footer: {
                Text("MeshChat sets it when it connects. Messages carry the time they were sent, so a wrong clock shows them out of order for others.")
            }

            Section {
                Button("Restart radio…") { confirmRestart = true }
                    .disabled(!model.isConnected || busy)
            }

            Section {
                Button("Erase radio…", role: .destructive) { confirmErase = true }
                    .disabled(!model.isConnected || busy)
            } footer: {
                Text("Chat history on this iPhone stays.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About this radio")
        .task(id: model.isConnected) {
            await model.refreshBattery()
            clock = model.isConnected ? try? await model.engine.radioTime() : nil
        }
        .confirmationDialog("Restart the radio?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") { run(String(localized: "Radio restarting. MeshChat reconnects when it's back, in about 15 seconds.")) { try await model.engine.reboot() } }
        } message: { Text("It's offline for about 15 seconds. Settings and messages waiting on it are kept.") }
        .confirmationDialog("Erase the radio?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase…", role: .destructive) { typedName = ""; typingName = true }
        } message: {
            Text(eraseWarning)
        }
        .alert("Type the radio's name to erase it", isPresented: $typingName) {
            TextField(model.me?.name ?? String(localized: "Name"), text: $typedName)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) { erase() }
                .disabled(typedName.trimmingCharacters(in: .whitespaces) != model.me?.name)
        } message: { Text(model.me.map { String(localized: "“\($0.name)”") } ?? "") }
        .alert(message ?? "", isPresented: .present($message)) { Button("OK") {} }
    }

    private var eraseWarning: String {
        var s = String(localized: "Erases its identity key, contacts, channels and settings. Others will see you as a new node and must add you again, and the Bluetooth PIN goes back to 123456. This can't be undone.")
        if model.savedRadio?.isBluetooth == false {
            s += " " + String(localized: "Over WiFi it forgets your WiFi network too: it starts its own setup network as on first use, and MeshChat can't reach it until WiFi is set up again.")
        }
        return s
    }

    private func erase() {
        guard typedName.trimmingCharacters(in: .whitespaces) == model.me?.name else { return }
        run(String(localized: "Erasing. The radio restarts as new; set it up again before reconnecting.")) { try await model.engine.factoryReset() }
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); message = done } catch { message = "\(error)" }
        }
    }
}

/// A network shared as a link or QR code (meshcore://network/add…): scanned, from a picture, or pasted.
private struct AddNetworkFromCodeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddFromCodeView(initial: nil) { _ in dismiss() }
                .navigationTitle("Add a network")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The radio's Bluetooth pairing PIN, for Settings › Connection.
struct BluetoothPinSection: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            TextField("New PIN (6 digits)", text: $pin)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: pin) { _, p in pin = String(p.filter(\.isNumber).prefix(6)) }
            Button("Save PIN") {
                let p = pin
                pin = ""
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await model.engine.setDevicePin(p)
                        message = String(localized: "PIN saved. Phones use it after the radio restarts; ones already paired need to forget the radio and pair again.")
                    } catch { message = "\(error)" }
                }
            }
            .disabled(BluetoothPin(pin) == nil || !model.isConnected || busy)
        } header: { Text("Bluetooth PIN") } footer: {
            Text(String(localized: "For pairing over Bluetooth: six digits, not starting with 0.")
                 + (model.device?.blePin == 123456 ? " " + String(localized: "The radio still uses the firmware's default PIN 123456, so anyone nearby could pair with it.") : ""))
        }
        .alert(message ?? "", isPresented: .present($message)) { Button("OK") {} }
    }
}

/// Where distances are measured from and the map starts: this iPhone's location, typed, or pasted from
/// a maps app. Kept on this iPhone only; never sent to the radio or the mesh.
struct HomeLocationView: View {
    @Environment(AppModel.self) private var model
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var pasted = ""
    @State private var locating = false
    @State private var problem: String?
    @State private var locator = DeviceLocation()

    var parsed: Position? {
        guard let la = Double(latitude.replacingOccurrences(of: ",", with: ".")), let lo = Double(longitude.replacingOccurrences(of: ",", with: ".")),
              abs(la) <= 90, abs(lo) <= 180 else { return nil }
        return Position(latitude: la, longitude: lo)
    }

    var body: some View {
        Form {
            Section {
                Button { Task { await locate() } } label: {
                    if locating { HStack { ProgressView(); Text("Finding you…") } } else { Label("Use this iPhone's location", systemImage: "location") }
                }
                .disabled(locating)
                TextField("Latitude", text: $latitude)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                TextField("Longitude", text: $longitude)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                Button("Save") { model.home = parsed; problem = nil }
                    .disabled(parsed == nil || parsed == model.home)
            } header: { Text("Home") } footer: {
                // (the coordinates as they're typed and pasted: a point for the decimals, whatever the language)
                Text((model.home.map { String(localized: "Saved: \(String(format: "%.5f, %.5f", $0.latitude, $0.longitude)).") } ?? String(localized: "Not set.")) + " ")
                + Text("Used for distances and directions to nodes, naming repeaters (the nearest of those sharing an ID) and the map. It stays on this iPhone and is never sent to the radio or the mesh.")
            }
            Section {
                TextField("52.2297, 21.0122 or a maps link", text: $pasted, axis: .vertical)
                    .autocorrectionDisabled()
                    .onSubmit(readPasted)
                Button("Read coordinates", action: readPasted).disabled(pasted.isEmpty)
            } header: { Text("Paste from a maps app") }
            if model.home != nil {
                Section {
                    Button("Clear home", role: .destructive) { model.home = nil; latitude = ""; longitude = "" }
                }
            }
            if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Home location")
        .onAppear {
            if let h = model.home { latitude = String(format: "%.5f", h.latitude); longitude = String(format: "%.5f", h.longitude) }
        }
    }

    private func readPasted() {
        if let p = Geo.parseCoordinates(pasted) {
            latitude = String(format: "%.5f", p.latitude); longitude = String(format: "%.5f", p.longitude); problem = nil
        } else { problem = String(localized: "No coordinates found in that.") }
    }

    private func locate() async {
        locating = true; defer { locating = false }
        do {
            let p = try await locator.current()
            latitude = String(format: "%.5f", p.latitude); longitude = String(format: "%.5f", p.longitude); problem = nil
        } catch { problem = "\(error)" }
    }
}

/// One location fix, asking for permission the first time.
@MainActor
final class DeviceLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Failure: Error, CustomStringConvertible {
        case denied, unavailable
        var description: String {
            switch self {
            case .denied: String(localized: "Location access is off for MeshChat. Turn it on in the Settings app, or type the coordinates.")
            case .unavailable: String(localized: "This iPhone couldn't find its location just now.")
            }
        }
    }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Position, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> Position {
        waiting?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { c in
            waiting = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(Failure.denied))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ r: Result<Position, Error>) {
        waiting?.resume(with: r)
        waiting = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard waiting != nil else { return }
        switch m.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(.failure(Failure.denied))
        default: m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        finish(.success(Position(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(Failure.unavailable))
    }
}
