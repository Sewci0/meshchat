import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Everything known about one message: when, how far, how strong, every copy heard, the route with
/// repeater names and distances, and its packet byte by byte.
struct MessageDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: Message
    @State private var info: MessageInfo?
    @State private var selected: Int64?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message.text).textSelection(.enabled)
                } header: {
                    if message.direction != .incoming { Text("You, to \(model.title(of: message.conversation))") }
                    else if let sender = message.sender { Text("From \(sender)") } else { Text("From unknown") }
                }
                glance
                if let info, let copy = info.copies.first(where: { $0.id == selected }) ?? info.copies.first {
                    RouteSteps(ids: NodeDirectory.split(copy.packet.path, hashSize: copy.packet.hashSize), outgoing: false,
                               from: message.direction == .incoming ? (message.sender ?? String(localized: "Sender")) : String(localized: "You"),
                               to: message.direction == .incoming ? String(localized: "You") : String(localized: "You (echo)"), lastSNR: copy.packet.snr)
                    mapButton(copy)
                    if info.copies.count > 1 { copies(info) }
                    AnatomySection(raw: copy.packet.raw, message: info.message,
                                   copy: info.copies.count > 1 ? (info.copies.firstIndex { $0.id == copy.id } ?? 0) + 1 : nil)
                } else {
                    Section("Route") { Text("No copy of this message's packet is in the log.").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .repeaterLinks()
            .navigationTitle("Message details")
            .task(id: model.packetVersion) { info = MessageInfo(message: (try? model.store.message(message.id ?? 0)) ?? message, store: model.store) }
        }
    }

    @ViewBuilder private var glance: some View {
        let m = info?.message ?? message
        Section("At a glance") {
            LabeledContent(m.direction == .incoming ? "Received" : "Sent", value: m.date.formatted(date: .abbreviated, time: .standard))
            if let skew = info?.clockSkew, m.direction == .incoming {
                let by = Duration.seconds(abs(skew)).formatted(.units(width: .abbreviated))
                LabeledContent("Sender's clock", value: abs(skew) <= 5 ? String(localized: "in step") : skew < 0 ? String(localized: "\(by) ahead") : String(localized: "\(by) behind"))
            }
            if let h = m.hops { LabeledContent("Hops", value: h == 0 ? String(localized: "direct") : String(localized: "\(h) (\(m.hashSize)-byte IDs)")) }
            if let snr = m.snr { LabeledContent("Signal", value: String(format: "%.2f dB", snr) + (m.rssi.map { ", \($0) dBm" } ?? "")) }
            if let info { LabeledContent(m.direction == .incoming ? "Copies heard" : "Echoes heard", value: info.copies.count > 1 ? String(localized: "\(info.copies.count) over \(info.routes) routes") : "\(info.copies.count)") }
            if m.direction == .outgoing {
                LabeledContent("Status", value: Self.statusText(m.status))
                if let tries = m.triesFlood {
                    LabeledContent("Tries", value: tries.map { $0 ? String(localized: "flood") : String(localized: "route") }.joined(separator: " → "))
                }
                if let t = m.ackTry {
                    LabeledContent("Receipt", value: m.roundTripMs.map { String(localized: "try \(t), after \(Duration.milliseconds($0).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))") } ?? String(localized: "try \(t)"))
                }
            }
        }
    }

    /// A status as shown (its raw value is what's stored, so stays as it is).
    private static func statusText(_ s: MessageStatus) -> String {
        switch s {
        case .received: String(localized: "received")
        case .sending: String(localized: "sending")
        case .sent: String(localized: "sent")
        case .repeated: String(localized: "repeated")
        case .notHeard: String(localized: "not heard")
        case .delivered: String(localized: "delivered")
        case .noAck: String(localized: "no ack")
        case .failed: String(localized: "failed")
        }
    }

    /// This copy's route on the map, when there's something to draw.
    @ViewBuilder private func mapButton(_ copy: MessageInfo.Copy) -> some View {
        let route = route(of: copy)
        if route.isDrawable {
            Section {
                Button { dismiss(); model.showRoute(route) } label: {
                    Label("Show route on map", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            } footer: {
                if route.hidden > 0 {
                    Text(route.hidden == 1 ? "1 of its repeaters has no known position, so the line skips it."
                                           : "\(route.hidden) of its repeaters have no known position, so the line skips them.")
                }
            }
        }
    }

    private func route(of copy: MessageInfo.Copy) -> MapRoute {
        var m = info?.message ?? message
        m.path = copy.packet.path
        m.hashSize = copy.packet.hashSize
        var sender: Contact?
        if m.direction == .incoming {
            if case .direct(let k) = m.conversation { sender = model.contacts[k] }
            else if let s = m.sender { sender = model.contacts.values.first { $0.name == s && $0.type == .companion } }
        }
        return MapRoute.of(m, directory: model.directory, sender: sender)
    }

    private func copies(_ info: MessageInfo) -> some View {
        Section("Copies") {
            ForEach(info.copies) { c in
                Button { selected = c.id } label: {
                    HStack {
                        Text(c.after < 0.001 ? "first" : "+\(Duration.seconds(c.after).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
                            .monospacedDigit().frame(width: 70, alignment: .leading)
                        Text(c.packet.hops == 0 ? "direct" : "\(c.packet.hops) hops")
                        Spacer()
                        Text(String(format: "%.2f dB", c.packet.snr)).monospacedDigit().foregroundStyle(.secondary)
                        if c.id == (selected ?? info.copies.first?.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }
}

/// A path as steps: sender → each repeater (ID, name, distance to the next) → receiver.
struct RouteSteps: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    /// a saved route (you first) rather than a received path (origin first)
    let outgoing: Bool
    let from: String
    let to: String
    var lastSNR: Double?

    var body: some View {
        let dir = model.directory
        let hops = outgoing ? dir.resolve(outgoing: ids) : dir.resolve(incoming: ids)
        Section {
            step(from, systemImage: "person", detail: outgoing ? String(localized: "sends it") : String(localized: "wrote it"))
            ForEach(Array(hops.enumerated()), id: \.offset) { i, h in
                let next = i + 1 < hops.count ? hops[i + 1].node?.position : (outgoing ? nil : model.home)
                let leg = h.node?.position.flatMap { p in next.map { Geo.km(p, $0) } }
                let row = step(h.node?.name ?? String(localized: "Unknown repeater"), systemImage: "antenna.radiowaves.left.and.right",
                               detail: [h.id, h.candidates > 1 ? String(localized: "\(h.candidates) share this ID: nearest shown") : nil,
                                        leg.map { String(localized: "\(String(format: "%.1f", $0)) km to the next") }].compactMap { $0 }.joined(separator: " · "))
                if let n = h.node { NavigationLink(value: RepeaterLink(key: n.key)) { row } } else { row }
            }
            step(to, systemImage: "person.fill", detail: lastSNR.map { String(localized: "heard it at \(String(format: "%.2f", $0)) dB") } ?? "")
        } header: {
            Text("Route")
        } footer: {
            Text(ids.isEmpty ? "No repeater in between." : "\(ids.count + 1) transmissions.")
        }
    }

    private func step(_ title: String, systemImage: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: systemImage) }
    }
}

/// The packet field by field, with its size, airtime and what the routing costs.
struct AnatomySection: View {
    @Environment(AppModel.self) private var model
    let raw: Data
    /// the message inside, decrypted (for what's inside the ciphertext)
    var message: Message?
    /// which copy, when there are several
    var copy: Int?

    var body: some View {
        if let a = PacketAnatomy(raw: raw) {
            let names = model.directory.resolve(incoming: a.hops)
            Section {
                overview(a)
                ForEach(a.fields) { f in field(f, a, names: names) }
                Button { copyToClipboard(raw.hex) } label: { Label("Copy hex", systemImage: "doc.on.doc") }
            } header: {
                if let copy { Text("The packet, byte by byte (copy \(copy))") } else { Text("The packet, byte by byte") }
            }
        }
    }

    // MARK: the whole packet at a glance

    private func overview(_ a: PacketAnatomy) -> some View {
        let radio = model.me?.radio
        let segments = a.fields.map { (part: $0.part, bytes: $0.hex.count / 2, label: $0.label) }
        let parts = segments.map(\.part).reduce(into: [PacketAnatomy.Part]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(a.total)").font(.title2.weight(.semibold)).monospacedDigit()
                + Text(" of \(PacketAnatomy.maxPacket) bytes").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let r = radio {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("≈ \(Int(PacketAnatomy.airtimeMs(bytes: a.total, r).rounded())) ms on air").font(.subheadline.weight(.medium)).monospacedDigit()
                        Text("SF\(r.spreadingFactor) · \(r.bandwidthKHz.formatted()) kHz · CR 4/\(r.codingRate)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            SizeBar(segments: segments.map { ($0.bytes, PartStyle.color($0.part)) }, capacity: PacketAnatomy.maxPacket)
                .frame(height: 12)
                .accessibilityElement()
                .accessibilityLabel((segments.map { String(localized: "\($0.label) \($0.bytes) bytes") }
                                     + [String(localized: "\(PacketAnatomy.maxPacket - a.total) unused")]).joined(separator: ", "))
            FlowLayout(spacing: 10, lineSpacing: 4) {
                ForEach(parts, id: \.self) { p in
                    HStack(spacing: 4) {
                        Circle().fill(PartStyle.color(p)).frame(width: 8, height: 8)
                        Text("\(PartStyle.name(p)) \(segments.filter { $0.part == p }.reduce(0) { $0 + $1.bytes }) B")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                stat(String(localized: "routing"), "\(a.routing) B")
                stat(String(localized: "payload"), String(localized: "\(a.payload) of \(PacketAnatomy.maxPayload) B"))
                stat(String(localized: "route can grow to"), String(localized: "\(a.maxHops) hops"))
                if let r = radio, a.pathAirtimeMs(r) >= 0.5 { stat(String(localized: "path airtime"), "≈ \(Int(a.pathAirtimeMs(r).rounded())) ms") }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: each field

    private func field(_ f: PacketAnatomy.Field, _ a: PacketAnatomy, names: [ResolvedHop]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(PartStyle.color(f.part)).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.label).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(f.hex.count / 2) B").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if f.part == .path {
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(Array(a.hops.enumerated()), id: \.offset) { i, h in
                            let n = i < names.count ? names[i] : nil
                            let chip = HStack(spacing: 4) {
                                Text(h).font(.caption.monospaced()).foregroundStyle(.primary)
                                Text(n?.node.map { $0.name + ((n?.candidates ?? 0) > 1 ? " (+\((n?.candidates ?? 1) - 1))" : "") } ?? String(localized: "unknown"))
                                    .font(.caption).foregroundStyle(n?.node == nil ? Color.secondary : Color.accentColor).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                            // each chip opens its repeater (borderless, so one row can hold several)
                            if let node = n?.node {
                                NavigationLink(value: RepeaterLink(key: node.key)) { chip }
                                    .buttonStyle(.borderless)
                                    .accessibilityHint("Opens the repeater")
                            } else {
                                chip
                            }
                        }
                    }
                } else {
                    // in 4-byte groups, so long fields wrap between groups, not mid-byte with a hyphen
                    Text(Self.grouped(f.hex)).font(.caption.monospaced()).textSelection(.enabled)
                }
                if f.label == "Header" {
                    BitGroups(byte: a.headerByte, groups: [(2, String(localized: "version \(a.version)")), (4, Self.typeLabel(a.typeName)),
                                                           (2, String(localized: "\(a.routeName) route", comment: "flood, direct, transport flood or transport direct"))])
                }
                if f.label == "Path length" {
                    BitGroups(byte: a.pathLengthByte, groups: [(2, String(localized: "\(a.hashSize)-byte repeater IDs")),
                                                               (6, a.hops.count == 1 ? String(localized: "1 hop") : String(localized: "\(a.hops.count) hops"))])
                }
                if let n = note(f, a) { Text(n).font(.caption).foregroundStyle(.secondary) }
                if f.part == .cipher { inside(a) }
            }
        }
        .padding(.vertical, 2)
    }

    static func grouped(_ hex: String) -> String {
        var out = "", i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 8, limitedBy: hex.endIndex) ?? hex.endIndex
            out += (out.isEmpty ? "" : " ") + hex[i..<j]
            i = j
        }
        return out
    }

    /// What a field is, under its bytes; the header's bits say it all themselves.
    private func note(_ f: PacketAnatomy.Field, _ a: PacketAnatomy) -> String? {
        switch f.label {
        case "Header": nil
        case "Path length":
            a.hashSize == 1
                ? String(localized: "With \(a.hashSize)-byte IDs a route can hold \(a.maxHops) hops (\(PacketAnatomy.maxPath) bytes of path); only 256 IDs, so repeaters often share one.")
                : String(localized: "With \(a.hashSize)-byte IDs a route can hold \(a.maxHops) hops (\(PacketAnatomy.maxPath) bytes of path).")
        default: f.note
        }
    }

    /// "GRP_TXT · channel message"
    static func typeLabel(_ name: String) -> String {
        let plain = ["REQ": String(localized: "request"), "RESPONSE": String(localized: "response"), "TXT_MSG": String(localized: "direct message"),
                     "ACK": String(localized: "receipt"), "ADVERT": String(localized: "advert"), "GRP_TXT": String(localized: "channel message"),
                     "GRP_DATA": String(localized: "channel data"), "ANON_REQ": String(localized: "login"), "PATH": String(localized: "route back"),
                     "TRACE": String(localized: "trace"), "MULTIPART": String(localized: "multipart"), "CONTROL": String(localized: "control")][name]
        return plain.map { "\(name) · \($0)" } ?? name
    }

    /// Inside the ciphertext, once decrypted: timestamp (4), flags (1), the text, zero padding to a block.
    @ViewBuilder private func inside(_ a: PacketAnatomy) -> some View {
        if let message { inside(a, message) }
    }

    @ViewBuilder private func inside(_ a: PacketAnatomy, _ message: Message) -> some View {
        let me = model.me?.name ?? message.sender ?? ""
        let plain: String = {
            if case .direct = message.conversation { return message.text }
            return "\(message.direction == .outgoing ? me : message.sender ?? ""): \(message.text)"
        }()
        let text = plain.utf8.count, pad = a.cipher - 5 - text
        if pad >= 0, pad < 16 {
            VStack(alignment: .leading, spacing: 4) {
                Text("inside, once decrypted:").font(.caption2).foregroundStyle(.secondary)
                SizeBar(segments: [(4, PartStyle.timestamp), (1, PartStyle.flags), (text, PartStyle.text), (pad, Color.secondary.opacity(0.25))], capacity: nil)
                    .frame(height: 8)
                    .accessibilityHidden(true)
                Text([message.senderTimestamp.map { String(localized: "timestamp 4 B (\(Date(timeIntervalSince1970: Double($0)).formatted(date: .omitted, time: .standard)))") }
                          ?? String(localized: "timestamp 4 B"),
                      String(localized: "flags 1 B"), String(localized: "text \(text) B"), String(localized: "padding \(pad) B")].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

/// The packet's parts in the web app's colours.
enum PartStyle {
    static func color(_ p: PacketAnatomy.Part) -> Color {
        switch p {
        case .header: Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8b / 255)      // slate
        case .transport: Color(red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255)   // amber
        case .path: Color(red: 0x0e / 255, green: 0xa5 / 255, blue: 0xe9 / 255)        // sky
        case .address: Color(red: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255)     // violet
        case .mac: Color(red: 0xf4 / 255, green: 0x3f / 255, blue: 0x5e / 255)         // rose
        case .cipher, .payload: Color(red: 0x10 / 255, green: 0xb9 / 255, blue: 0x81 / 255)  // emerald
        }
    }

    static func name(_ p: PacketAnatomy.Part) -> String {
        switch p {
        case .header: String(localized: "header")
        case .transport: String(localized: "transport codes")
        case .path: String(localized: "path")
        case .address: String(localized: "addresses")
        case .mac: String(localized: "MAC")
        case .cipher: String(localized: "ciphertext")
        case .payload: String(localized: "payload")
        }
    }

    static let timestamp = Color(red: 0x94 / 255, green: 0xa3 / 255, blue: 0xb8 / 255)
    static let flags = Color(red: 0xfb / 255, green: 0xbf / 255, blue: 0x24 / 255)
    static let text = Color(red: 0x34 / 255, green: 0xd3 / 255, blue: 0x99 / 255)
}

/// A bar split into segments as wide as their byte counts, the rest of `capacity` left plain.
struct SizeBar: View {
    let segments: [(Int, Color)]
    let capacity: Int?

    var body: some View {
        GeometryReader { g in
            let gap = 2.0
            let used = segments.reduce(0) { $0 + $1.0 }
            let total = Double(max(capacity ?? used, used, 1))
            let room = g.size.width - gap * Double(segments.count)
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    RoundedRectangle(cornerRadius: 2).fill(s.1).frame(width: max(2, room * Double(s.0) / total))
                }
                if capacity != nil { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)) }
            }
            .clipShape(.rect(cornerRadius: 4))
        }
    }
}

/// One byte as its bit groups, a row each: the group's bits in their place in the byte (the rest
/// dotted), then what they mean.
///     00······  version 1
///     ··0101··  GRP_TXT · channel message
///     ······01  flood route
struct BitGroups: View {
    let byte: UInt8
    let groups: [(Int, String)]

    var body: some View {
        let b = String(byte, radix: 2)
        let all = Array(String(repeating: "0", count: 8 - b.count) + b)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                let start = groups.prefix(i).reduce(0) { $0 + $1.0 }
                GridRow {
                    Text(String(repeating: "·", count: start) + String(all[start..<start + g.0]) + String(repeating: "·", count: 8 - start - g.0))
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
                    Text(g.1).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Bits \(String(all[start..<start + g.0])): \(g.1)")
            }
        }
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(s.width, width)
            if !items.isEmpty, x + spacing + w > width {
                rows.append((items, x, h)); items = []; x = 0; h = 0
            }
            x += (items.isEmpty ? 0 : spacing) + w
            h = max(h, s.height)
            items.append(i)
        }
        if !items.isEmpty { rows.append((items, x, h)) }
        return rows
    }
}

/// The saved route to a contact or room: its repeaters, history, how your messages went, what it costs
/// on air, and Reset path.
struct RouteDetailsView: View {
    @Environment(AppModel.self) private var model
    let key: PublicKey
    @State private var history: RouteHistory?
    @State private var stats = DeliveryStats([])
    @State private var confirmReset = false
    @State private var error: String?

    var contact: Contact? { model.contacts[key] }

    var body: some View {
        Form {
            if let c = contact {
                Section {
                    LabeledContent("Route", value: c.outPath.map { $0.hops.isEmpty ? String(localized: "direct") : String(localized: "\($0.hops.count) hops") }
                                   ?? String(localized: "none: messages flood"))
                    if let h = history {
                        LabeledContent("Learned", value: h.learned.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "before MeshChat kept track"))
                        LabeledContent("Changes", value: String(localized: "\(h.changes) of \(h.learns) learned"))
                    }
                    LabeledContent("Delivered", value: stats.sent == 0 ? "—" : String(localized: "\(stats.delivered) of the last \(stats.sent)"))
                    if let r = stats.medianRoundTripOnRoute { LabeledContent("Round trip on the route", value: Duration.milliseconds(r).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))) }
                    if let r = stats.medianRoundTripByFlood { LabeledContent("Round trip by flood", value: Duration.milliseconds(r).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))) }
                }
                if let p = c.outPath {
                    RouteSteps(ids: p.hops.map(\.hex), outgoing: true, from: String(localized: "You"), to: c.name)
                    onAir(p)
                } else {
                    Section { Text("No saved route. The next message floods: every repeater that hears it passes it on once, and \(c.name)'s answer brings back the path it took.") }
                }
                if let h = history { historySection(h) }
                if !stats.recent.isEmpty { recent }
                Section {
                    Button("Reset path", role: .destructive) { confirmReset = true }.disabled(c.outPath == nil || !model.isConnected)
                        .confirmationDialog("Forget the route to \(contact?.name ?? "")?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset path", role: .destructive) {
                                Task { do { try await model.engine.resetPath(key) } catch { self.error = "\(error)" } }
                            }
                        } message: { Text("The next message floods, which costs more airtime once, and learns a fresh route.") }
                } footer: {
                    Text(stats.recentMisses >= 2 && c.outPath != nil
                         ? "\(stats.recentMisses) of your last messages got no receipt: a repeater on the route may be off. Resetting makes the next one find a new way."
                         : "Routes mostly heal themselves: a DM's last try floods and the receipt brings a new route. Reset when you know the route is wrong.")
                }
            } else {
                ContentUnavailableView("Not a contact", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .formStyle(.grouped)
        .repeaterLinks()
        .navigationTitle("Route to \(contact?.name ?? "")")
        .task(id: model.routeVersion &+ (model.messageVersion[.direct(key)] ?? 0)) {
            history = try? model.store.route(key.hex)
            stats = DeliveryStats((try? model.store.messages(in: .direct(key))) ?? [])
        }
        .alert(error ?? "", isPresented: .present($error)) { Button("OK") { error = nil } }
    }

    private func historySection(_ h: RouteHistory) -> some View {
        Section("History") {
            if let c = h.confirmed, let l = h.learned, c.timeIntervalSince(l) > 30 { LabeledContent("Learned again", value: c.formatted(.relative(presentation: .named))) }
            if let hops = h.viaHops {
                LabeledContent("Came back", value: h.viaSNR.map { String(localized: "PATH over \(hops) hops at \(String(format: "%.2f", $0)) dB") } ?? String(localized: "PATH over \(hops) hops"))
            }
            if let p = h.previous {
                let names = model.directory.resolve(outgoing: NodeDirectory.split(p.path, hashSize: p.hashSize)).map(\.label)
                LabeledContent("Before", value: names.isEmpty ? String(localized: "direct") : names.joined(separator: " → "))
            }
            if let r = h.reset {
                let when = r.formatted(.relative(presentation: .named))
                LabeledContent("Last reset", value: h.resetBy == "retry" ? String(localized: "\(when) by a DM's last try")
                               : h.resetBy == "you" ? String(localized: "\(when) by you") : String(localized: "\(when) by another app"))
            }
        }
    }

    private var recent: some View {
        Section("Your recent messages") {
            ForEach(Array(stats.recent.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0.text).lineLimit(1)
                    Text([item.0.ackTry.map { String(localized: "\(label(item.1)) on try \($0)", comment: "how it went, such as “delivered on the route”, then which try") } ?? label(item.1),
                          item.0.roundTripMs.map { String(localized: "receipt after \(Duration.milliseconds($0).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))") },
                          item.0.triesFlood.map { $0.map { $0 ? String(localized: "flood") : String(localized: "route") }.joined(separator: " → ") }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(item.1 == .noReceipt || item.1 == .failed ? .orange : .secondary)
                }
            }
        }
    }

    private func label(_ o: DeliveryStats.Outcome) -> String {
        switch o {
        case .onRoute: String(localized: "delivered on the route")
        case .byFlood: String(localized: "delivered by flood")
        case .delivered: String(localized: "delivered")
        case .noReceipt: String(localized: "no receipt")
        case .failed: String(localized: "not sent")
        case .pending: String(localized: "waiting")
        }
    }

    @ViewBuilder private func onAir(_ p: OutPath) -> some View {
        if let r = model.me?.radio {
            let bytes = 2 + p.bytes.count + 4 + 64, ack = 2 + p.bytes.count + 4
            let one = PacketAnatomy.airtimeMs(bytes: bytes, r), back = PacketAnatomy.airtimeMs(bytes: ack, r)
            Section("On air") {
                LabeledContent("A 50-character DM", value: String(localized: "\(bytes) bytes, \(Int(one)) ms a hop"))
                LabeledContent("With the receipt", value: String(localized: "\(Int((one + back) * Double(p.hops.count + 1))) ms in all"))
            }
        }
    }
}
