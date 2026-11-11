import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Asking a node how it is: a repeater's status (uptime, battery, traffic), and the readings of a
/// repeater, sensor or person (battery, temperature, position, its sensors). People answer only if they
/// share readings with you; repeaters and sensors are asked as a guest. Rooms aren't asked here: logging
/// in to one joins it (see the room's details).
struct NodeQueryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: PublicKey
    @State private var status: LiveAnswer?
    @State private var readings: TelemetryAnswer?
    @State private var askingStatus = false
    @State private var askingReadings = false

    private var contact: Contact? { model.contacts[key] }
    private var type: NodeType { contact?.type ?? .unknown }

    var body: some View {
        NavigationStack {
            Form {
                ConnectionNoticeSection()
                if contact == nil {
                    Section { Label("Add it to your contacts first: the radio asks only its contacts.", systemImage: "person.badge.plus") }
                }
                if type == .repeater { statusSections }
                readingsSection
            }
            .formStyle(.grouped)
            .navigationTitle(contact?.name ?? String(localized: "Ask"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                status = try? model.store.liveAnswer(key.hex)
                readings = try? model.store.telemetryAnswer(key.hex)
            }
        }
    }

    private var canAsk: Bool { model.isConnected && contact != nil && type != .room }

    @ViewBuilder private var statusSections: some View {
        let ask = Button { Task { await askStatus() } } label: { asking(askingStatus, "Ask for status", "Asking for status…") }
            .disabled(askingStatus || askingReadings || !canAsk)
        let about = Text("Logs in as a guest, asks for its status and the repeaters it hears, and logs out: a few moments of airtime.")
        if let a = status, let s = a.status.flatMap(NodeStatus.init) {
            StatusSection(status: s, asOf: a.date, room: false)   // headed "Status", dated
            Section { ask } footer: { about }
        } else {
            Section {
                if let e = status?.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ask
            } header: { Text("Status") } footer: { about }
        }
    }

    private var readingsSection: some View {
        Section {
            if let t = readings {
                if t.readings.isEmpty {
                    Label(t.error ?? String(localized: "It answered, but with no readings."), systemImage: t.error == nil ? "info.circle" : "exclamationmark.triangle")
                        .foregroundStyle(t.error == nil ? Color.secondary : .orange)
                }
                ForEach(Array(t.readings.enumerated()), id: \.offset) { _, r in
                    LabeledContent(r.label) { Text(r.text).monospacedDigit().textSelection(.enabled) }
                }
            }
            Button { Task { await askReadings() } } label: { asking(askingReadings, "Ask for readings", "Asking for readings…") }
                .disabled(askingStatus || askingReadings || !canAsk)
        } header: {
            Text(String(localized: "Readings") + (readings.map { " · " + $0.date.formatted(.relative(presentation: .named)) } ?? ""))
        } footer: {
            Text(type == .companion
                 ? "Battery, position and sensors, if they share them with you: each person chooses who may in their app (in MeshChat: Settings › Mesh behaviour)."
                 : type == .repeater ? "Asked as a guest, who gets its battery and temperature. More needs its admin password."
                 : "Asked as a guest: battery and what its sensors measure.")
        }
    }

    private func asking(_ busy: Bool, _ idle: LocalizedStringKey, _ working: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(busy ? working : idle)
        }
    }

    private func askStatus() async {
        askingStatus = true; defer { askingStatus = false }
        do { status = try await model.engine.query(key) } catch { status = nil }
    }

    private func askReadings() async {
        askingReadings = true; defer { askingReadings = false }
        do { readings = try await model.engine.telemetry(key) }
        catch { readings = TelemetryAnswer(key: key.hex, date: .now, error: String(localized: "Not asked: \(String(describing: error))")) }
    }
}

extension NodeType {
    /// What asking it gives: a repeater's status and readings, anyone else's readings (not a room's).
    var queryTitle: String? {
        switch self {
        case .repeater: String(localized: "Status and readings…")
        case .companion, .sensor: String(localized: "Ask for readings…")
        default: nil
        }
    }
}
