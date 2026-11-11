import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Settings › Position shared on the mesh: what your adverts give as your position. None; a fixed point
/// (typed, pasted, home, or where you are now); or the phone's GPS, kept current while MeshChat is open.
struct NodeLocationView: View {
    @Environment(AppModel.self) private var model
    @State private var source: AppModel.LocationSource = .none
    @State private var text = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var done: String?
    @State private var locator = DeviceLocation()

    var body: some View {
        let parsed = Geo.parseCoordinates(text)
        Form {
            ConnectionNoticeSection()
            Section {
                Picker("Source", selection: $source) {
                    ForEach(AppModel.LocationSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(explanation + " " + String(localized: "This is separate from Home location, which never leaves this iPhone."))
            }
            switch source {
            case .none:
                Section {
                    Button("Stop sharing my position") { apply(.none, nil) }
                        .disabled(busy || !model.isConnected || model.me?.advertLocationPolicy == 0)
                }
            case .fixed:
                Section {
                    TextField("52.2297, 21.0122 or a maps link", text: $text, axis: .vertical)
                        .autocorrectionDisabled()
                    if let h = model.home {
                        Button("Use my home location") { text = Self.format(h) }
                    }
                    Button { Task { await here() } } label: { Label("Use where I am now", systemImage: "location") }
                        .disabled(busy)
                    Button("Share this position") { if let p = parsed { apply(.fixed, p) } }
                        .disabled(parsed == nil || busy || !model.isConnected)
                } header: {
                    Text("Position")
                } footer: {
                    Text(parsed.map { String(localized: "Shares \(Self.format($0)).") } ?? (text.isEmpty ? "" : String(localized: "No coordinates in that.")))
                }
            case .phone:
                Section {
                    Button("Share the phone's position") { Task { await startPhone() } }
                        .disabled(busy || !model.isConnected)
                    if let f = model.lastPhoneFix {
                        LabeledContent("Last sent", value: "\(Self.format(f.position)), \(f.at.formatted(.relative(presentation: .named)))")
                    }
                } footer: {
                    Text("Sent to the radio when you've moved more than 200 m, or every 30 minutes, while MeshChat is open.")
                }
            }
            if let me = model.me {
                Section("On the radio now") {
                    LabeledContent("Adverts", value: me.advertLocationPolicy == 0 ? String(localized: "No position") : String(localized: "Include a position"))
                    if me.advertLocationPolicy != 0, let p = me.position { LabeledContent("Position", value: Self.format(p)) }
                }
            }
            RadioGPSSection()
            if busy { Section { HStack { ProgressView(); Text("Setting it on the radio…") } } }
            if let done { Section { Label(done, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Shared position")
        .onAppear {
            source = model.locationSource
            if let p = model.me?.position { text = Self.format(p) }
        }
        .onChange(of: source) { done = nil; problem = nil }
    }

    private var explanation: String {
        switch source {
        case .none: String(localized: "Your adverts carry no position: you aren't on anyone's map. Your rough area can still be guessed from the first repeater your packets reach.")
        case .fixed: String(localized: "Your adverts carry this position, so others see you on their map. Everyone on the mesh can read it: round it off if you'd rather not give your address.")
        case .phone: String(localized: "Your adverts carry where your phone is, so others see you on their map, and it follows you while MeshChat is open. Everyone on the mesh can read it.")
        }
    }

    static func format(_ p: Position) -> String { String(format: "%.5f, %.5f", p.latitude, p.longitude) }

    private func apply(_ s: AppModel.LocationSource, _ p: Position?) {
        busy = true; problem = nil; done = nil
        Task {
            defer { busy = false }
            do {
                try await model.setLocation(s, position: p)
                done = String(localized: "Set. Others see it after your next advert.")
            } catch { problem = "\(error)" }
        }
    }

    private func here() async {
        busy = true; defer { busy = false }
        do { text = Self.format(try await locator.current()) } catch { problem = "\(error)" }
    }

    private func startPhone() async {
        busy = true; problem = nil; done = nil
        defer { busy = false }
        do {
            let p = try await locator.current()
            try await model.setLocation(.phone, position: p)
            done = String(localized: "Sharing the phone's position. Others see it after your next advert.")
        } catch { problem = "\(error)" }
    }
}

/// While the phone's GPS is the source: a fix every 5 minutes, sent on when it moved.
struct PhoneLocationFollower: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var locator = DeviceLocation()

    func body(content: Content) -> some View {
        content.task(id: model.locationSource == .phone && model.isConnected) {
            guard model.locationSource == .phone && model.isConnected else { return }
            while !Task.isCancelled {
                if let p = try? await locator.current() { await model.phoneMoved(to: p) }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}
