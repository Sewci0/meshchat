import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Every node the radio has heard on its network or added as a contact: type, hops, last-hop signal,
/// distance and when it was last heard. Contacts heard only on other networks come after, and what other
/// networks had is behind a row of its own. Sort and filter; tap one for everything known about it.
struct NodesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @AppStorage("nodesType") private var typeRaw = -1
    @AppStorage("nodesSort") private var sort: NodeRow.Sort = .heard
    @AppStorage("nodesShow") private var show: NodeRow.Show = .all
    @AppStorage("nodesHideStale") private var hideStale = false
    @State private var tidying = false
    @State private var problem: String?

    var type: NodeType? { typeRaw < 0 ? nil : NodeType(rawValue: UInt8(typeRaw)) }
    private var filtered: Bool { type != nil || show != .all || hideStale }

    var body: some View {
        let rows = NodeRow.all(contacts: model.contactsHere, heard: model.heard, home: model.distanceOrigin,
                               type: type, query: query, sort: sort)
            .filter { $0.shown(show, hideStale: hideStale) }
        // contacts heard only on other networks: listed apart, as they may be out of reach here
        let elsewhere = show == .heardOnly ? [] : NodeRow.all(contacts: model.contacts.values.filter(model.onlyElsewhere), heard: [],
                                                             home: model.distanceOrigin, type: type, query: query, sort: sort)
            .filter { $0.shown(show, hideStale: hideStale) }
        let others = model.heardByNetwork.others
        NavigationStack {
            List {
                if model.contactsFullNotice { fullNotice }
                if model.distanceOrigin == nil {
                    NavigationLink { HomeLocationView() } label: {
                        Label("Set your home location to see how far each node is", systemImage: "location")
                            .font(.subheadline)
                    }
                }
                Section {
                    ForEach(rows) { nodeRow($0) }
                } header: {
                    if let name = model.networkName, !rows.isEmpty { Text("\(name) · \(rows.count)") }
                }
                if !elsewhere.isEmpty {
                    Section {
                        ForEach(elsewhere) { nodeRow($0) }
                    } header: {
                        Text("Contacts not heard on this network · \(elsewhere.count)")
                    } footer: {
                        Text("Your radio heard them on another network, so they may be out of reach here.")
                    }
                }
                if !others.isEmpty && query.isEmpty {
                    Section {
                        NavigationLink { OtherNetworksView() } label: {
                            LabeledContent { Text("\(others.count)").monospacedDigit() } label: {
                                Label("Other networks", systemImage: "point.3.filled.connected.trianglepath.dotted")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search by name")
            .tabTitle("Nodes")
            .navigationDestination(for: String.self) { NodeDetailView(key: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Type", selection: $typeRaw) {
                            Text("All").tag(-1)
                            Text("People").tag(Int(NodeType.companion.rawValue))
                            Text("Repeaters").tag(Int(NodeType.repeater.rawValue))
                            Text("Rooms").tag(Int(NodeType.room.rawValue))
                            Text("Sensors").tag(Int(NodeType.sensor.rawValue))
                        }
                        Picker("Show", selection: $show) {
                            Text("All nodes").tag(NodeRow.Show.all)
                            Text("Contacts on the radio").tag(NodeRow.Show.contacts)
                            Text("Heard, not contacts").tag(NodeRow.Show.heardOnly)
                        }
                        Toggle("Hide not heard for a month", isOn: $hideStale)
                        Picker("Sort by", selection: $sort) {
                            Text("Last heard").tag(NodeRow.Sort.heard)
                            Text("Name").tag(NodeRow.Sort.name)
                            Text("Distance").tag(NodeRow.Sort.distance)
                            Text("Hops").tag(NodeRow.Sort.hops)
                        }
                        Section {
                            Button { tidying = true } label: { Label("Tidy contacts…", systemImage: "person.2.badge.minus") }
                                .disabled(!model.isConnected)
                        }
                    } label: { Label("Filter and sort", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                }
            }
            .sheet(isPresented: $tidying) { TidyContactsView() }
            .alert(problem ?? "", isPresented: .present($problem)) { Button("OK") {} }
            .overlay {
                if rows.isEmpty && elsewhere.isEmpty {
                    if !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if filtered {
                        ContentUnavailableView("No nodes match", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Change the filter to see more."))
                    } else if query.isEmpty && type == nil {
                        ContentUnavailableView(model.networkName.map { String(localized: "Nothing heard on \($0) yet") } ?? String(localized: "Nothing heard yet"),
                                               systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text(others.isEmpty
                                                                 ? "Nodes appear as your radio hears their adverts."
                                                                 : "Nodes appear as your radio hears their adverts. What it heard on other networks is under Other networks."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .task(id: model.packetVersion / 20) { model.reloadHeard() }   // now and then, as adverts arrive
        }
    }

    private func nodeRow(_ r: NodeRow) -> some View {
        NavigationLink(value: r.key) { NodeRowView(row: r) }
            .swipeActions(edge: .leading) {
                if let c = r.contact, model.isConnected {
                    Button { favourite(c, !c.isFavourite) } label: {
                        Label(c.isFavourite ? "Unstar" : "Star", systemImage: c.isFavourite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
            }
    }

    /// The radio said its contact list is full: it stops adding nodes it hears until there's room.
    private var fullNotice: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Your radio's contact list is full", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { model.contactsFullNotice = false } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
                }
                Text("It isn't adding new nodes it hears. Let it replace the ones unheard longest, or tidy the list now.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Make room automatically") { Task { await makeRoom() } }
                        .buttonStyle(.borderedProminent)
                    Button("Tidy…") { tidying = true }
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .disabled(!model.isConnected)
            }
            .padding(.vertical, 4)
        }
    }

    private func makeRoom() async {
        do { try await model.makeRoomWhenFull() } catch { problem = String(localized: "Not changed: \(String(describing: error))") }
    }

    private func favourite(_ c: Contact, _ on: Bool) {
        Task {
            do { try await model.engine.setFavourite(c.key, on) } catch { problem = String(localized: "Not changed: \(String(describing: error))") }
        }
    }
}

struct NodeRowView: View {
    @Environment(AppModel.self) private var model
    let row: NodeRow

    var body: some View {
        HStack {
            Avatar(name: row.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.name).lineLimit(1)
                    if row.contact?.isFavourite == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Favourite") }
                }
                Text([row.type.label, row.hops.map { $0 == 0 ? String(localized: "direct") : String(localized: "\($0) hops") },
                      row.lastSeen.map { $0.formatted(.relative(presentation: .named)) },
                      row.contact == nil ? String(localized: "not a contact") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // how far, and how strongly heard: on the right, where the eye looks for numbers
            VStack(alignment: .trailing, spacing: 2) {
                if let km = row.km {
                    Text(km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km))
                        .font(.subheadline.monospacedDigit())
                }
                if let snr = row.heard?.snr {
                    Text(String(format: "%.1f dB", snr)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One node: what's known about it, and what you can do (message, route, repeater page, map, add or remove).
struct NodeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var confirmRemove = false
    @State private var asking = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        let row = NodeRow.all(contacts: Array(model.contacts.values), heard: model.heard, home: model.distanceOrigin).first { $0.key == key }
        Form {
            if let row {
                Section {
                    HStack(spacing: 12) {
                        Avatar(name: row.name, size: 48)
                        VStack(alignment: .leading) {
                            Text(row.name).font(.headline)
                            Text(row.type.label + (row.contact == nil ? " · " + String(localized: "heard, not a contact") : "")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if let h = row.hops { LabeledContent("Hops", value: h == 0 ? String(localized: "direct") : "\(h)") }
                    if let h = row.heard {
                        LabeledContent(h.hops == 0 ? "Signal" : "Last-hop signal", value: String(format: "%.2f dB, %d dBm", h.snr, h.rssi))
                        LabeledContent("Adverts heard", value: String(localized: "\(h.count) since \(h.firstHeard.formatted(date: .abbreviated, time: .omitted))"))
                        LabeledContent("Last heard", value: h.lastHeard.formatted(.relative(presentation: .named)))
                    }
                    // a contact heard only on another network: which, and when
                    if row.heard == nil, let h = model.heardByNetwork.anywhere.first(where: { $0.key == key }),
                       !h.network.isEmpty, h.network != model.network {
                        LabeledContent("Heard on", value: model.radioProfiles.name(forNetwork: h.network))
                        LabeledContent("Last heard there", value: h.lastHeard.formatted(.relative(presentation: .named)))
                    }
                    if let c = row.contact { LabeledContent("Last advert", value: ago(c.lastAdvert)) }
                    if let km = row.km, let p = row.position, let origin = model.distanceOrigin {
                        LabeledContent(model.home == nil ? "Distance from your radio" : "Distance",
                                       value: String(localized: "\(String(format: "%.1f", km)) km \(Geo.bearing(origin, p))", comment: "a distance, then which way: north, north-east…"))
                    }
                    if let p = row.position { LabeledContent("Position", value: String(format: "%.5f, %.5f", p.latitude, p.longitude)).textSelection(.enabled) }
                    LabeledContent("Key") { Text(String(key.prefix(16)) + "…").font(.body.monospaced()) }
                        .contextMenu { Button("Copy key") { copyToClipboard(key) } }
                } footer: {
                    if row.heard.map({ $0.hops > 0 }) == true { Text("Last-hop signal: the repeater that passed its advert to you, not the node itself.") }
                }
                actions(row)
                if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            } else {
                ContentUnavailableView("Not known any more", systemImage: "questionmark.circle")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row?.name ?? String(localized: "Node"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder private func actions(_ row: NodeRow) -> some View {
        let pk = PublicKey(hex: key)
        Section {
            if let pk, let c = row.contact {
                if c.type == .companion || c.type == .room {
                    Button { model.open(.direct(pk)) } label: { Label(c.type == .room ? "Open room" : "Message", systemImage: "bubble.left") }
                }
                if let title = c.type.queryTitle {
                    Button { asking = true } label: { Label(title, systemImage: "gauge.with.dots.needle.33percent") }
                        .sheet(isPresented: $asking) { NodeQueryView(key: pk) }
                }
                NavigationLink { RouteDetailsView(key: pk) } label: { Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                ShareLink(item: MeshLink.contactLink(name: c.name, key: pk, type: c.type)) { Label("Share contact link", systemImage: "square.and.arrow.up") }
            }
            if row.type == .repeater || row.type == .room {
                Button { model.showRepeater(key) } label: { Label("Repeater activity", systemImage: "antenna.radiowaves.left.and.right") }
            }
            if row.position != nil {
                Button { model.showOnMap(key) } label: { Label("Show on map", systemImage: "map") }
            }
            if row.contact == nil, let pk {
                Button { Task { await add(pk, row) } } label: { Label("Add to contacts", systemImage: "person.badge.plus") }
                    .disabled(busy || !model.isConnected)
            }
        }
        if let c = row.contact, c.type == .companion || c.type == .room {
            Section {
                if model.isBlocked(c) {
                    Button("Unblock \(c.name)") {
                        model.blockList.entries.filter { $0.key == c.key.hex || $0.name == c.name }.forEach(model.unblock)
                    }
                } else {
                    Button(role: .destructive) { model.block(name: c.name, key: c.key.hex) } label: { Label("Block \(c.name)", systemImage: "hand.raised") }
                }
            } footer: {
                Text("Blocking hides their messages on this iPhone and stops them notifying you. They aren't told.")
            }
        }
        if let pk, let c = row.contact {
            Section {
                Button { Task { await favourite(pk, !c.isFavourite) } } label: {
                    Label(c.isFavourite ? "Remove from favourites" : "Add to favourites", systemImage: c.isFavourite ? "star.slash" : "star")
                }
                .disabled(busy || !model.isConnected)
            } footer: {
                Text("The radio never removes a favourite to make room, and tidying contacts keeps it.")
            }
        }
        if row.contact != nil {
            Section {
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from contacts…", systemImage: "person.badge.minus") }
                    .disabled(busy || !model.isConnected)
                    .confirmationDialog("Remove \(row.name) from contacts?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { Task { await remove() } }
                    } message: { Text("The radio forgets it and its route. Messages here stay. It can come back from its next advert, or its QR code.") }
            }
        }
    }

    private func add(_ pk: PublicKey, _ row: NodeRow) async {
        busy = true; defer { busy = false }
        do { _ = try await model.engine.addContact(key: pk, name: row.name, type: row.type); problem = nil }
        catch { problem = String(localized: "Not added: \(String(describing: error))") }
    }

    private func favourite(_ pk: PublicKey, _ on: Bool) async {
        busy = true; defer { busy = false }
        do { try await model.engine.setFavourite(pk, on); problem = nil }
        catch { problem = String(localized: "Not changed: \(String(describing: error))") }
    }

    private func remove() async {
        guard let pk = PublicKey(hex: key) else { return }
        busy = true; defer { busy = false }
        do { try await model.engine.removeContact(pk); problem = nil }
        catch { problem = String(localized: "Not removed: \(String(describing: error))") }
    }
}

extension NodeType {
    var label: String {
        switch self {
        case .companion: String(localized: "Person")
        case .repeater: String(localized: "Repeater")
        case .room: String(localized: "Room server")
        case .sensor: String(localized: "Sensor")
        default: String(localized: "Node")
        }
    }
}

/// What the radio heard while on other networks: a network each (its saved name, else its settings),
/// then its nodes. Only to look at: here, they're out of reach.
struct OtherNetworksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.heardByNetwork.others) { n in
                    NavigationLink { ElsewhereNodesView(network: n) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.radioProfiles.name(forNetwork: n.network))
                            Text(n.nodes.count == 1 ? "1 node · last heard \(n.lastHeard.formatted(.relative(presentation: .named)))"
                                                    : "\(n.nodes.count) nodes · last heard \(n.lastHeard.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Nodes your radio heard while on other networks. To hear them again, put it on that network in Settings › Network.")
            }
        }
        .navigationTitle("Other networks")
    }
}

/// The nodes heard on one other network, most recently heard first.
struct ElsewhereNodesView: View {
    @Environment(AppModel.self) private var model
    let network: HeardByNetwork.Elsewhere

    var body: some View {
        List(network.nodes.sorted { $0.lastHeard.timeIntervalSince1970 > $1.lastHeard.timeIntervalSince1970 }) { h in
            HStack {
                Avatar(name: h.name, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.name).lineLimit(1)
                    Text([NodeType(raw: UInt8(clamping: h.type)).label, h.hops == 0 ? String(localized: "direct") : String(localized: "\(h.hops) hops"),
                          h.lastHeard.formatted(.relative(presentation: .named))].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .navigationTitle(model.radioProfiles.name(forNetwork: network.network))
    }
}
