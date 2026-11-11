import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Everything the radio decodes on its network, live, newest first. Pause to read without the list
/// moving; tap a packet for its route and its bytes.
struct PacketsView: View {
    @Environment(AppModel.self) private var model
    @State private var packets: [PacketRecord] = []
    @State private var paused = false
    @State private var type: String?

    var body: some View {
        let dir = model.directory
        let shown = packets.filter { type == nil || $0.type == type }
        List {
            Section {
                ForEach(shown) { p in
                    NavigationLink { PacketDetailView(packet: p) } label: { PacketRow(packet: p, directory: dir) }
                }
            } header: {
                if let name = model.networkName, !shown.isEmpty { Text(name) }
            }
        }
        .navigationTitle("Packets")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Type", selection: $type) {
                        Text("All types").tag(String?.none)
                        ForEach(Array(Set(packets.map(\.type))).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filter", systemImage: type == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                Button { paused.toggle() } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(packets.isEmpty ? "No packets yet" : "None of this type", systemImage: "waveform",
                                       description: Text("They appear here the moment your radio decodes one."))
            }
        }
        .task(id: paused ? "paused" : "\(model.packetVersion)/\(model.network ?? "")") {
            guard !paused else { return }
            packets = (try? model.store.packets(limit: 300, network: model.network)) ?? []
        }
    }
}

struct PacketRow: View {
    let packet: PacketRecord
    let directory: NodeDirectory

    var body: some View {
        let hops = directory.resolve(incoming: NodeDirectory.split(packet.path, hashSize: packet.hashSize))
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(packet.type).font(.subheadline.weight(.medium).monospaced())
                Text(packet.route).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(packet.date, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text(hops.isEmpty ? String(localized: "direct") : hops.map(\.label).joined(separator: " → ")).lineLimit(1)
                Spacer()
                Text(String(format: "%.1f dB · %d dBm · %d B", packet.snr, packet.rssi, packet.raw.count))
                    .monospacedDigit().layoutPriority(1)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One packet: when, how strong, the repeaters it came through, and every field.
struct PacketDetailView: View {
    @Environment(AppModel.self) private var model
    let packet: PacketRecord

    var body: some View {
        Form {
            Section {
                LabeledContent("Heard", value: packet.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Type", value: packet.type)
                LabeledContent("Route", value: packet.route)
                LabeledContent("Signal", value: String(format: "%.2f dB, %d dBm", packet.snr, packet.rssi))
                LabeledContent("Fingerprint", value: String(format: "%08x", UInt32(truncatingIfNeeded: packet.fingerprint))).font(.body.monospaced())
            }
            RouteSteps(ids: NodeDirectory.split(packet.path, hashSize: packet.hashSize), outgoing: false,
                       from: String(localized: "Sender"), to: String(localized: "You"), lastSNR: packet.snr)
            AnatomySection(raw: packet.raw)
            Section("Raw") {
                Text(packet.raw.hex).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .repeaterLinks()
        .navigationTitle(packet.type)
        .toolbar {
            ShareLink(item: packet.raw.hex, subject: Text("MeshCore packet"), message: Text(packet.type)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
