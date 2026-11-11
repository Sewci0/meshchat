import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Channels, listened channels, rooms and direct messages, with unread markers.
struct ChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ConversationID?
    @State private var joining = false
    @State private var newMessage = false
    @State private var browsingRooms = false
    @State private var codes = false
    @State private var codesLink: String?
    @State private var deleting: ConversationID?
    @State private var problem: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if model.savedRadio != nil, !model.isConnected { Section { ConnectionNotice() } }
                Section("Channels") {
                    ForEach(model.channels, id: \.index) { ch in
                        row(.channel(ch.index), icon: "number", title: ch.name.hasPrefix("#") ? String(ch.name.dropFirst()) : ch.name)
                    }
                }
                if !model.listened.isEmpty {
                    Section("Listening") {
                        ForEach(model.listened, id: \.name) { l in row(.listened(l.name), icon: "ear", title: String(l.name.dropFirst())) }
                    }
                }
                Section("Rooms") {
                    ForEach(model.roomList, id: \.self) { c in row(c, icon: "person.3", title: model.title(of: c)) }
                    Button { browsingRooms = true } label: {
                        Label("Browse rooms heard nearby", systemImage: "magnifyingglass")
                    }
                }
                Section("Direct messages") {
                    ForEach(model.directList, id: \.self) { c in row(c, icon: nil, title: model.title(of: c)) }
                    if model.directList.isEmpty {
                        Text("Start one from + › New message, or touch and hold a message in a channel.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .tabTitle("MeshChat")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { newMessage = true } label: { Label("New message", systemImage: "square.and.pencil") }
                        Button { joining = true } label: { Label("Join or listen to a channel", systemImage: "number") }
                        Button { browsingRooms = true } label: { Label("Browse rooms", systemImage: "person.3") }
                        Divider()
                        Button { codes = true } label: { Label("Contacts by QR code", systemImage: "qrcode") }
                    } label: { Label("New", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $joining) { JoinChannelView() }
            .sheet(isPresented: $newMessage) {
                NewMessageView { c in selection = c; newMessage = false }
            }
            .sheet(isPresented: $browsingRooms) {
                NavigationStack {
                    RoomsBrowserView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { browsingRooms = false } } }
                }
            }
            .sheet(isPresented: $codes, onDismiss: { codesLink = nil }) { ContactCodesView(link: codesLink) { c in selection = c } }
            .alert(problem ?? "", isPresented: .present($problem)) { Button("OK") {} }
            .onAppear(perform: openRequested)
            .onChange(of: model.openConversation) { openRequested() }
            .onChange(of: model.pendingLink) { openRequested() }
        } detail: {
            if let selection {
                NavigationStack { ConversationView(conversation: selection) }.id(selection)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private func deleteTitle(_ c: ConversationID) -> String {
        switch c {
        case .channel: String(localized: "Delete \(model.title(of: c))?")
        case .listened(let n): String(localized: "Stop listening to \(n)?")
        case .direct:
            model.isRoom(c)
                ? String(localized: "Leave \(model.title(of: c))?")
                : String(localized: "Delete the conversation with \(model.title(of: c))?")
        }
    }

    private func deleteMessage(_ c: ConversationID) -> String {
        switch c {
        case .channel: String(localized: "Leaves the channel on your radio, freeing its slot, and deletes its messages from this iPhone. You can join it again any time.")
        case .listened: String(localized: "Deletes its messages from this iPhone. You can listen again any time.")
        case .direct:
            model.isRoom(c)
                ? String(localized: "The room stops reaching this iPhone. You can join it again from Browse rooms.")
                : String(localized: "Deletes its messages from this iPhone; \(model.title(of: c)) keeps theirs and stays in your contacts.")
        }
    }

    private func delete(_ c: ConversationID, keepingPosts: Bool = false) {
        if selection == c { selection = nil }
        Task {
            do { try await model.delete(c, keepingPosts: keepingPosts) } catch { problem = String(localized: "Couldn't delete it: \(String(describing: error))") }
        }
    }

    private func openRequested() {
        if let c = model.openConversation { selection = c; model.openConversation = nil }
        if let l = model.pendingLink { codesLink = l; codes = true; model.pendingLink = nil }
    }

    private func row(_ c: ConversationID, icon: String?, title: String) -> some View {
        NavigationLink(value: c) {
            HStack {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 28) } else { Avatar(name: title, size: 28) }
                Text(title).fontWeight(model.isUnread(c) ? .semibold : .regular).lineLimit(1)
                SilencedMark(conversation: c)
                Spacer()
                if model.isUnread(c) {
                    Circle().fill(.tint).frame(width: 8, height: 8).accessibilityLabel("Unread")
                }
            }
        }
        .contextMenu {
            NotifyMenu(conversation: c)
            if model.isUnread(c) { Button { model.markRead(c) } label: { Label("Mark as read", systemImage: "envelope.open") } }
            Button(role: .destructive) { deleting = c } label: {
                Label(model.isRoom(c) ? "Leave…" : "Delete…", systemImage: model.isRoom(c) ? "rectangle.portrait.and.arrow.right" : "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if model.isUnread(c) { Button { model.markRead(c) } label: { Label("Mark as read", systemImage: "envelope.open") }.tint(.accentColor) }
        }
        .swipeActions(edge: .trailing) {
            Button { deleting = c } label: {
                Label(model.isRoom(c) ? "Leave" : "Delete", systemImage: model.isRoom(c) ? "rectangle.portrait.and.arrow.right" : "trash")
            }
            .tint(.red)
        }
        // on the row, so the question points at the conversation it's about
        .confirmationDialog(deleteTitle(c), isPresented: Binding(get: { deleting == c }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if model.isRoom(c) {
                Button("Leave and delete posts", role: .destructive) { delete(c) }
                Button("Leave, keep posts") { delete(c, keepingPosts: true) }
            } else {
                Button("Delete", role: .destructive) { delete(c) }
            }
        } message: { Text(deleteMessage(c)) }
    }
}

/// Initials on a colour that's stable per name.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first).map(String.init).joined()
        Circle()
            .fill(Color(hue: hue, saturation: 0.25, brightness: 0.92))
            .overlay(Text(letters.isEmpty ? "?" : letters.uppercased()).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Color(hue: hue, saturation: 0.6, brightness: 0.4)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Join a hashtag channel (or a private one with its key), or listen to one without joining.
struct JoinChannelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var secret = ""
    @State private var error: String?
    @State private var busy = false

    var tag: String { let n = name.trimmingCharacters(in: .whitespaces).lowercased(); return n.hasPrefix("#") ? n : "#" + n }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("#polska", text: $name).autocorrectionDisabled()
                    TextField("Secret (private channels only, 32 hex characters)", text: $secret).autocorrectionDisabled().font(.body.monospaced())
                } footer: {
                    Text("Hashtag channels are open: anyone who knows the name can read them. Private channels need the secret from whoever made them.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Join \(name.isEmpty ? "" : tag)") { Task { await join() } }.disabled(name.isEmpty || busy)
                    if secret.isEmpty {
                        Button("Listen only (no channel slot, can't send)") {
                            Task { do { try await model.engine.listen(to: tag); dismiss() } catch { self.error = "\(error)" } }
                        }
                        .disabled(name.isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Join a channel")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func join() async {
        busy = true; defer { busy = false }
        var key: Data?
        if !secret.isEmpty {
            guard let k = Data(hex: secret), k.count == 16 else { error = String(localized: "A secret is 32 hexadecimal characters."); return }
            key = k
        }
        do {
            _ = try await model.engine.joinChannel(name: key == nil ? tag : name, secret: key)
            dismiss()
        } catch { self.error = "\(error)" }
    }
}

/// People the radio knows, to start a DM with.
struct NewMessageView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    let open: (ConversationID) -> Void

    var body: some View {
        let people = model.contacts.values.filter { $0.type == .companion && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.lastAdvert > $1.lastAdvert }
        // heard on the radio's network first: those heard only on another may be out of reach
        let here = people.filter { !model.onlyElsewhere($0) }, elsewhere = people.filter(model.onlyElsewhere)
        NavigationStack {
            List {
                if elsewhere.isEmpty {
                    ForEach(here) { person($0) }
                } else {
                    if !here.isEmpty { Section("Heard on this network") { ForEach(here) { person($0) } } }
                    Section {
                        ForEach(elsewhere) { person($0) }
                    } header: {
                        Text("Not heard here yet")
                    } footer: {
                        Text("Heard on another network: a message may not reach them until they're on yours.")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .navigationTitle("New message")
            .overlay {
                if model.contacts.isEmpty { ContentUnavailableView("No contacts yet", systemImage: "person.2", description: Text("People appear after their advert reaches your radio.")) }
            }
        }
    }

    private func person(_ c: Contact) -> some View {
        Button { open(.direct(c.key)) } label: {
            HStack { Avatar(name: c.name, size: 28); Text(c.name); Spacer(); Text(ago(c.lastAdvert)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}


/// "5 min ago", "3 h ago" from a node's own clock (which may be wrong).
func ago(_ seconds: UInt32) -> String {
    guard seconds > 0 else { return String(localized: "never") }
    let d = Date().timeIntervalSince1970 - Double(seconds)
    if d < 0 { return String(localized: "clock ahead") }
    return Date(timeIntervalSince1970: Double(seconds)).formatted(.relative(presentation: .named))
}
