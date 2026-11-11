import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Joining a room: a login, as a guest with no password if the room allows it. The room then sends the
/// posts newer than the newest you have, one at a time, and each new one.
struct JoinRoomView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: PublicKey
    @State private var password = ""
    @State private var busy = false
    @State private var result: LiveAnswer?

    var room: Contact? { model.contacts[key] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password (if the room has one)", text: $password)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Without one you join as a guest, if the room allows guests (some only let guests read). A wrong password gets no answer at all. MeshChat doesn't keep it.")
                }
                if busy { Section { HStack { ProgressView(); Text("Logging in… answers take 5–30 seconds.") } } }
                if let r = result, !r.ok { Section { Label(r.error ?? String(localized: "No answer"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            }
            .formStyle(.grouped)
            .navigationTitle(room.map { String(localized: "Join \($0.name)") } ?? String(localized: "Join room"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Join") { Task { await join() } }.disabled(busy || !model.isConnected) }
            }
        }
    }

    private func join() async {
        busy = true; defer { busy = false }
        let pwd = password
        password = ""   // not kept
        result = try? await model.engine.query(key, password: pwd)
        if result?.ok == true { dismiss() }
    }
}

/// A room: your standing, its posts and authors, its status, and the route to it.
struct RoomDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: PublicKey
    @State private var answer: LiveAnswer?
    @State private var posts: [Message] = []
    @State private var joining = false
    @State private var confirmLeave = false

    var membership: RoomMembership? { model.rooms[key.hex] }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    LabeledContent("Standing", value: membership.map { $0.left ? String(localized: "left") : RoomRole.label($0.role) }
                                   ?? (posts.isEmpty ? String(localized: "not joined") : String(localized: "member")))
                    if let m = membership, !m.left { Text(RoomRole.explanation(m.role)).font(.footnote).foregroundStyle(.secondary) }
                    if let l = membership?.loginAt { LabeledContent("Last login", value: l.formatted(.relative(presentation: .named))) }
                    Button(membership.map { $0.left ? String(localized: "Join again") : String(localized: "Log in again") } ?? String(localized: "Join")) { joining = true }
                        .disabled(!model.isConnected)
                    if membership?.left == false {
                        Button("Leave room", role: .destructive) { confirmLeave = true }
                            .confirmationDialog("Leave this room?", isPresented: $confirmLeave, titleVisibility: .visible) {
                                Button("Leave", role: .destructive) { Task { try? await model.engine.leaveRoom(key); dismiss() } }
                            } message: { Text("Its posts stay here; new ones are ignored. You can join again any time.") }
                    }
                }
                Section("Posts") {
                    let incoming = posts.filter { $0.direction == .incoming }
                    LabeledContent("Here", value: "\(incoming.count)")
                    LabeledContent("Authors", value: "\(Set(incoming.compactMap(\.sender)).count)")
                    if let newest = incoming.compactMap(\.senderTimestamp).max() {
                        LabeledContent("Newest", value: Date(timeIntervalSince1970: Double(newest)).formatted(.relative(presentation: .named)))
                    }
                }
                if let s = answer?.status.flatMap(NodeStatus.init) { StatusSection(status: s, asOf: answer?.date, room: true) }
                Section {
                    NavigationLink("Route") { RouteDetailsView(key: key) }
                } footer: {
                    Text("MeshCore has no “leave” message: the room keeps sending new posts while your radio confirms them, so after leaving MeshChat ignores them.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.contacts[key]?.name ?? String(localized: "Room"))
            .task(id: model.routeVersion &+ (model.messageVersion[.direct(key)] ?? 0)) {
                answer = try? model.store.liveAnswer(key.hex)
                posts = (try? model.store.messages(in: .direct(key))) ?? []
            }
            .sheet(isPresented: $joining) { JoinRoomView(key: key) }
        }
    }
}

/// A repeater's or room's stats.
struct StatusSection: View {
    let status: NodeStatus
    let asOf: Date?
    let room: Bool

    var body: some View {
        Section {
            LabeledContent("Up for", value: Duration.seconds(status.uptimeSeconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            if room, let p = status.roomPosts {
                LabeledContent("Posts", value: [String(localized: "\(p.posted) stored"), String(localized: "\(p.pushes) pushed to members")].joined(separator: " · "))
            }
            if status.batteryMillivolts > 0 { LabeledContent("Battery", value: String(format: "%.2f V", Double(status.batteryMillivolts) / 1000)) }
            LabeledContent("Last packet", value: String(format: "%.2f dB, %d dBm", status.lastSNR, status.lastRSSI))
            LabeledContent("Noise floor", value: "\(status.noiseFloor) dBm")
            LabeledContent("Traffic", value: [String(localized: "\(status.packetsReceived) in"), String(localized: "\(status.packetsSent) out")].joined(separator: " · "))
            LabeledContent("Sent", value: [String(localized: "\(status.sentDirect) direct"), String(localized: "\(status.sentFlood) flood")].joined(separator: " · "))
            LabeledContent("Airtime", value: Duration.seconds(status.airtimeSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
        } header: {
            Text("Status")
        } footer: {
            if let asOf { Text("As of \(asOf.formatted(.relative(presentation: .named))).") }
        }
    }
}

/// Room servers your radio has heard on the mesh. Nothing comes from the internet, so it works
/// offline: rooms appear when their adverts reach your radio. Joined first; search, show only joined,
/// sort; join, add and join, open, or show on the map.
struct RoomsBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var joining: PublicKey?
    @State private var adding: String?
    @State private var query = ""
    @State private var problem: String?
    @AppStorage("roomsJoinedOnly") private var joinedOnly = false
    @AppStorage("roomsSort") private var sort: RoomEntry.Sort = .distance

    var body: some View {
        let all = RoomEntry.all(contacts: Array(model.contacts.values), heard: model.heard, rooms: model.rooms,
                                conversations: model.conversations, home: model.distanceOrigin)
        let entries = RoomEntry.shown(all, query: query, joinedOnly: joinedOnly, sort: sort)
        List {
            Section {
                ForEach(entries) { r in row(r) }
            } header: {
                if !all.isEmpty { Text("\(all.count) heard · \(all.filter(\.isMember).count) joined") }
            } footer: {
                Text("Rooms your radio has heard over the mesh: no internet needed. A room server keeps posts and passes them to everyone who joined. New rooms appear when their adverts reach you, usually a few times a day.")
            }
        }
        .searchable(text: $query, prompt: "Search rooms")
        .navigationTitle("Rooms")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $joinedOnly) { Text("All rooms").tag(false); Text("Joined").tag(true) }
                    Picker("Sort by", selection: $sort) {
                        Text("Distance").tag(RoomEntry.Sort.distance)
                        Text("Last advert").tag(RoomEntry.Sort.heard)
                        Text("Posts").tag(RoomEntry.Sort.posts)
                        Text("Name").tag(RoomEntry.Sort.name)
                    }
                } label: {
                    Label("Filter and sort", systemImage: joinedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("No room servers heard yet", systemImage: "person.3",
                                       description: Text("Rooms appear when their adverts reach your radio, usually a few times a day."))
            } else if entries.isEmpty {
                if query.isEmpty { ContentUnavailableView("No joined rooms", systemImage: "person.3", description: Text("Show all rooms to join one.")) }
                else { ContentUnavailableView.search(text: query) }
            }
        }
        .sheet(item: $joining) { JoinRoomView(key: $0) }
        .alert(problem ?? "", isPresented: .present($problem)) { Button("OK") {} }
        .onAppear { model.reloadHeard() }
    }

    private func row(_ r: RoomEntry) -> some View {
        let key = PublicKey(hex: r.key)
        return HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.caption)
                .foregroundStyle(r.isMember ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(r.isMember ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                Text([standing(r), r.posts > 0 ? (r.posts == 1 ? String(localized: "1 post") : String(localized: "\(r.posts) posts")) : nil,
                      r.km.map { String(format: "%.0f km", $0) + (r.bearing.map { " \($0)" } ?? "") }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(r.isMember ? Color.green : .secondary).lineLimit(1)
                Text([heard(r), route(r), r.lastAdvert.map { String(localized: "advert \($0.formatted(.relative(presentation: .named)))") }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let c = r.contact {
                if r.membership == nil || r.membership?.left == true {
                    Button(r.membership?.left == true ? "Join again" : r.isMember ? "Log in" : "Join") { joining = c.key }
                        .buttonStyle(.bordered).controlSize(.small).disabled(!model.isConnected)
                }
            } else if key != nil {
                Button("Add & join") { Task { await addAndJoin(r) } }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!model.isConnected || adding == r.key)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let c = r.contact { dismiss(); model.open(.direct(c.key)) } }
        .contextMenu {
            if let c = r.contact {
                Button { dismiss(); model.open(.direct(c.key)) } label: { Label("Open", systemImage: "bubble.left.and.bubble.right") }
            }
            if r.position != nil {
                Button { dismiss(); model.showOnMap(r.key) } label: { Label("Show on map", systemImage: "map") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { if let c = r.contact { dismiss(); model.open(.direct(c.key)) } }
    }

    private func standing(_ r: RoomEntry) -> String {
        if r.membership?.left == true { return String(localized: "left") }
        if let m = r.membership { return RoomRole.label(m.role) }
        if r.isMember { return String(localized: "member") }
        return r.contact == nil ? String(localized: "not a contact") : String(localized: "not joined")
    }

    /// how its last advert reached you
    private func heard(_ r: RoomEntry) -> String? {
        guard let h = r.heard else { return nil }
        if h.hops == 0 { return String(localized: "heard direct \(String(format: "%.1f", h.snr)) dB") }
        return h.hops == 1 ? String(localized: "heard over 1 hop") : String(localized: "heard over \(h.hops) hops")
    }

    /// the radio's saved route to it
    private func route(_ r: RoomEntry) -> String? {
        guard let c = r.contact else { return nil }
        guard let p = c.outPath else { return String(localized: "route: flood") }
        if p.hops.isEmpty { return String(localized: "route: direct") }
        return p.hops.count == 1 ? String(localized: "route: 1 hop") : String(localized: "route: \(p.hops.count) hops")
    }

    /// A room heard but not a contact (the radio's contact list was full, say): add it from its advert,
    /// then open the join form.
    private func addAndJoin(_ r: RoomEntry) async {
        guard let key = PublicKey(hex: r.key) else { return }
        adding = r.key; defer { adding = nil }
        do {
            _ = try await model.engine.addContact(key: key, name: String(r.name.prefix(31)), type: .room)
            joining = key
        } catch { problem = String(localized: "Couldn't add \(r.name): \(String(describing: error))") }
    }
}

extension PublicKey: Identifiable {
    public var id: String { hex }
}
