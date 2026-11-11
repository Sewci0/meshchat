import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Settings › Mesh behaviour: how the radio takes part in the mesh. Which heard nodes become contacts,
/// who may read its telemetry, extra acknowledgements, and (advanced) path hash size, repeating, the
/// flood region and its timing. Each change goes to the radio as it's made; what the radio has is shown.
struct MeshBehaviourView: View {
    @Environment(AppModel.self) private var model
    @State private var autoAdd: AutoAddConfig?
    @State private var tuning: TuningParams?
    @State private var rxDelay = 0.0
    @State private var airtime = 0.0
    @State private var scope: FloodScope??
    @State private var scopeName = ""
    @State private var scopeKey = ""
    @State private var repeatRanges: [FrequencyRange]?
    @State private var advanced = false
    @State private var confirmHash: Int?
    @State private var confirmRepeat = false
    @State private var busy = false
    @State private var message: String?
    @State private var tidying = false

    private var other: OtherParams? { model.me?.otherParams }
    private var firmware: Int { model.device?.firmwareCode ?? 0 }

    var body: some View {
        Form {
            ConnectionNoticeSection()
            contacts
            telemetry
            Section {
                Toggle("Extra acknowledgements", isOn: Binding(get: { (other?.multiAcks ?? 0) != 0 }, set: { on in setOther { $0.multiAcks = on ? 1 : 0 } }))
                    .disabled(other == nil || !model.isConnected || busy)
            } header: { Text("Delivery") } footer: {
                Text("Sends each acknowledgement twice, so fewer of your contacts' messages show as not delivered. A little more airtime.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) { advancedRows }
            } footer: {
                if advanced, let d = model.device, firmware < 10 {
                    Text("Some settings need newer firmware (this radio: \(d.version)).")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mesh behaviour")
        .task(id: model.isConnected) { await load() }
        .confirmationDialog("Use \((confirmHash ?? 0) + 1)-byte path hashes?", isPresented: .present($confirmHash), titleVisibility: .visible) {
            Button("Change") { if let h = confirmHash { write(String(localized: "Path hash size changed.")) { try await model.engine.setPathHashMode(h) } } }
        } message: {
            Text("Older repeaters may not pass on 2- or 3-byte paths. If messages stop getting through, switch back to 1 byte.")
        }
        .confirmationDialog("Repeat other nodes' packets?", isPresented: $confirmRepeat, titleVisibility: .visible) {
            Button("Turn on") { write(String(localized: "Repeating on.")) { try await model.engine.setRepeat(true) } }
        } message: {
            Text("Your radio will pass on other people's packets. This uses battery and airtime; only turn it on if you're filling a gap in coverage.")
        }
        .alert(message ?? "", isPresented: .present($message)) { Button("OK") {} }
        .sheet(isPresented: $tidying) { TidyContactsView() }
    }

    // MARK: contacts

    @ViewBuilder private var contacts: some View {
        let addAll = other.map { $0.manualAddContacts & 1 == 0 } ?? true
        Section {
            Picker("Add heard nodes", selection: Binding(get: { addAll }, set: { all in setOther { $0.manualAddContacts = all ? $0.manualAddContacts & ~1 : $0.manualAddContacts | 1 } })) {
                Text("Every one").tag(true)
                Text("Only some kinds").tag(false)
            }
            .disabled(other == nil || !model.isConnected || busy)
            if let a = autoAdd {
                if !addAll {
                    kindToggle(String(localized: "People"), AutoAddConfig.people, a)
                    kindToggle(String(localized: "Repeaters"), AutoAddConfig.repeaters, a)
                    kindToggle(String(localized: "Rooms"), AutoAddConfig.rooms, a)
                    kindToggle(String(localized: "Sensors"), AutoAddConfig.sensors, a)
                }
                Stepper(value: Binding(get: { a.maxHops }, set: { h in changeAutoAdd { $0.maxHops = h } }), in: 0...64) {
                    LabeledContent(String(localized: "autoadd.from", defaultValue: "From", comment: "Mesh behaviour: the auto-add row; its value is how far away a node may be, e.g. \"Up to 2 hops\""), value: a.reachText)
                }
                .disabled(!model.isConnected || busy)
                Toggle("Make room when full", isOn: Binding(get: { a.has(AutoAddConfig.overwriteOldest) }, set: { on in changeAutoAdd { $0.flags = on ? $0.flags | AutoAddConfig.overwriteOldest : $0.flags & ~AutoAddConfig.overwriteOldest } }))
                    .disabled(!model.isConnected || busy)
            }
            Toggle("Star contacts you use", isOn: Binding(get: { model.starWhatYouUse }, set: { model.starWhatYouUse = $0 }))
            if let d = model.device, model.isConnected {
                let f = ContactTidy.fullness(count: model.contacts.count, max: d.maxContacts)
                Button { tidying = true } label: {
                    LabeledContent {
                        Text(f.text).monospacedDigit().foregroundStyle(f.nearlyFull ? .orange : .secondary)
                    } label: {
                        Text("Tidy contacts…").foregroundStyle(Color.accentColor)
                    }
                }
                .accessibilityLabel("Tidy contacts, \(f.text) on the radio")
            }
        } header: { Text("Contacts") } footer: {
            Text((addAll
                  ? String(localized: "The radio adds every node whose advert it hears as a contact.")
                  : String(localized: "The radio adds only these kinds by itself; add others from Nodes."))
                 + " " + String(localized: "Making room replaces the one unheard longest that isn't a favourite. Starring what you use marks people you message, rooms you join and repeaters you log in to as admin, so they stay; star others in Nodes."))
        }
    }

    private func kindToggle(_ title: String, _ flag: UInt8, _ a: AutoAddConfig) -> some View {
        Toggle(title, isOn: Binding(get: { a.has(flag) }, set: { on in changeAutoAdd { $0.flags = on ? $0.flags | flag : $0.flags & ~flag } }))
            .disabled(!model.isConnected || busy)
    }

    // MARK: telemetry

    @ViewBuilder private var telemetry: some View {
        let t = other.map { TelemetryModes(byte: $0.telemetryModes) }
        Section {
            telemetryPicker(String(localized: "Battery and status"), t?.base) { m in setOther { var x = TelemetryModes(byte: $0.telemetryModes); x.base = m; $0.telemetryModes = x.byte } }
            telemetryPicker(String(localized: "Location"), t?.location) { m in setOther { var x = TelemetryModes(byte: $0.telemetryModes); x.location = m; $0.telemetryModes = x.byte } }
            telemetryPicker(String(localized: "Sensors"), t?.environment) { m in setOther { var x = TelemetryModes(byte: $0.telemetryModes); x.environment = m; $0.telemetryModes = x.byte } }
        } header: { Text("Who may read its telemetry") } footer: {
            Text("Other nodes can ask your radio for these. “Contacts I allow” means contacts you've given permission.")
        }
    }

    private func telemetryPicker(_ title: String, _ value: TelemetryModes.Mode?, _ set: @escaping (TelemetryModes.Mode) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value ?? .nobody }, set: set)) {
            Text("Nobody").tag(TelemetryModes.Mode.nobody)
            Text("Contacts I allow").tag(TelemetryModes.Mode.allowed)
            Text("Everyone").tag(TelemetryModes.Mode.everyone)
        }
        .disabled(value == nil || !model.isConnected || busy)
    }

    // MARK: advanced

    @ViewBuilder private var advancedRows: some View {
        if firmware >= 10, let h = model.device?.pathHashMode {
            VStack(alignment: .leading, spacing: 6) {
                Text("Path hash size")
                Picker("Path hash size", selection: Binding(get: { h }, set: { new in if new != h { confirmHash = new } })) {
                    Text("1 byte").tag(0); Text("2 bytes").tag(1); Text("3 bytes").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.isConnected || busy)
                Text("Bigger hashes tell repeaters apart better but fit fewer hops in a packet. Everyone on your network should use the same.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if firmware >= 9, let on = model.device?.repeatEnabled {
            let allowed = repeatRanges.map { r in model.me.map { me in r.contains { $0.contains(mhz: me.radio.frequencyMHz) } } ?? false } ?? false
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Repeat packets", isOn: Binding(get: { on }, set: { new in
                    if new { confirmRepeat = true } else { write(String(localized: "Repeating off.")) { try await model.engine.setRepeat(false) } }
                }))
                .disabled(!model.isConnected || busy || (!on && !allowed))
                if let r = repeatRanges, !allowed {
                    Text(r.isEmpty ? "This radio doesn't repeat on any frequency." : "This radio only repeats on \(r.map(Self.describe).joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let scope {
            VStack(alignment: .leading, spacing: 6) {
                Text("Flood region")
                TextField("Region name", text: $scopeName).autocorrectionDisabled()
                TextField("Key (32 hex characters)", text: $scopeKey)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                HStack {
                    Button("Save region") {
                        guard let key = Data(hex: scopeKey.trimmingCharacters(in: .whitespaces).lowercased()), key.count == 16 else { message = String(localized: "The key is 32 hex characters."); return }
                        let s = FloodScope(name: scopeName.trimmingCharacters(in: .whitespaces), key: key)
                        write(String(localized: "Flood region saved.")) { try await model.engine.setFloodScope(s); self.scope = .some(s) }
                    }
                    .disabled(scopeName.trimmingCharacters(in: .whitespaces).isEmpty || scopeName.utf8.count > 30 || !model.isConnected || busy)
                    Spacer()
                    if scope != nil {
                        Button("Clear", role: .destructive) {
                            write(String(localized: "Flood region cleared.")) { try await model.engine.setFloodScope(nil); self.scope = .some(nil); scopeName = ""; scopeKey = "" }
                        }
                        .disabled(!model.isConnected || busy)
                    }
                }
                .buttonStyle(.borderless)
                Text("Floods you send carry this region, so repeaters outside it don't pass them on. Leave it clear to reach everyone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if tuning != nil {
            Stepper(value: $rxDelay, in: 0...20, step: 0.5) {
                LabeledContent("Receive delay", value: rxDelay == 0 ? String(localized: "Off") : rxDelay.formatted())
            }
            Stepper(value: $airtime, in: 0...9, step: 0.5) {
                LabeledContent("Airtime factor", value: airtime.formatted())
            }
            Button("Save timing") {
                let t = TuningParams(rxDelayBase: rxDelay, airtimeFactor: airtime)
                write(String(localized: "Timing saved.")) { try await model.engine.setTuning(t); tuning = t }
            }
            .disabled(tuning == TuningParams(rxDelayBase: rxDelay, airtimeFactor: airtime) || !model.isConnected || busy)
            Text("Receive delay waits longer before passing on weak packets, so stronger copies win. Airtime factor is the quiet time after sending, per second of sending.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "869.495 MHz", or "433.000–434.000 MHz"
    static func describe(_ r: FrequencyRange) -> String {
        r.lowerKHz == r.upperKHz ? String(format: "%.3f MHz", Double(r.lowerKHz) / 1000)
            : String(format: "%.3f–%.3f MHz", Double(r.lowerKHz) / 1000, Double(r.upperKHz) / 1000)
    }

    // MARK: talking to the radio

    /// What the radio has for the settings it keeps apart (the rest come with its own info).
    private func load() async {
        guard model.isConnected else { return }
        autoAdd = try? await model.engine.autoAdd()
        if let t = try? await model.engine.tuning() { tuning = t; rxDelay = t.rxDelayBase; airtime = t.airtimeFactor }
        do {
            let s = try await model.engine.floodScope()
            scope = .some(s)
            scopeName = s?.name ?? ""
            scopeKey = s?.key.hex ?? ""
        } catch { scope = nil }   // older firmware: no flood regions
        if firmware >= 9 { repeatRanges = try? await model.engine.repeatFrequencies() }
    }

    /// One of the settings sent together: read, change, send all (one at a time, so two quick changes
    /// don't undo each other).
    private func setOther(_ change: @escaping (inout OtherParams) -> Void) {
        guard var o = other else { return }
        change(&o)
        write(nil) { try await model.engine.setOtherParams(o) }
    }

    private func changeAutoAdd(_ change: (inout AutoAddConfig) -> Void) {
        guard var a = autoAdd else { return }
        let before = a
        change(&a)
        autoAdd = a
        write(nil, undo: { autoAdd = before }) { try await model.engine.setAutoAdd(a) }
    }

    private func write(_ done: String?, undo: (() -> Void)? = nil, _ action: @escaping () async throws -> Void) {
        guard !busy else { undo?(); return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); if let done { message = done } } catch { undo?(); message = String(localized: "Not changed: \(String(describing: error))") }
        }
    }
}

/// The radio's own GPS, on boards that have one: on or off, and how often it takes a fix. Hidden on
/// boards without (the radio lists its sensor settings, and "gps" is among them only when there is one).
struct RadioGPSSection: View {
    @Environment(AppModel.self) private var model
    @State private var gps: Bool?
    @State private var interval: Int?
    @State private var busy = false
    @State private var problem: String?

    private static let intervals = [(60, String(localized: "Every minute")), (300, String(localized: "Every 5 minutes")),
                                    (900, String(localized: "Every 15 minutes")), (3600, String(localized: "Every hour"))]

    var body: some View {
        Group {
            if let gps {
                Section {
                    Toggle("Radio's GPS", isOn: Binding(get: { gps }, set: { on in set("gps", on ? "1" : "0") { self.gps = on } }))
                        .disabled(!model.isConnected || busy)
                    if gps, let interval {
                        Picker("Position fix", selection: Binding(get: { interval }, set: { s in set("gps_interval", String(s)) { self.interval = s } })) {
                            ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                            if !Self.intervals.contains(where: { $0.0 == interval }) { Text("Every \(interval) s").tag(interval) }
                        }
                        .disabled(!model.isConnected || busy)
                    }
                } header: { Text("Radio GPS") } footer: {
                    if let problem { Text(problem).foregroundStyle(.orange) }
                    else { Text("The radio's own receiver: it sets the radio's position itself. Fixes more often use more battery.") }
                }
            }
        }
        .task(id: model.isConnected) {
            guard model.isConnected, let vars = try? await model.engine.customVars() else { return }
            gps = vars.first { $0.name == "gps" }.map { $0.value == "1" }
            interval = vars.first { $0.name == "gps_interval" }.flatMap { Int($0.value) }
        }
    }

    private func set(_ name: String, _ value: String, done: @escaping () -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await model.engine.setCustomVar(name, value); done(); problem = nil } catch { problem = String(localized: "Not changed: \(String(describing: error))") }
        }
    }
}
