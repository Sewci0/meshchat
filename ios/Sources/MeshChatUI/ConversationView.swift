import MeshChatCore
import MeshCoreKit
import SwiftUI

/// A conversation: messages grouped by sender, newest at the bottom, and the composer. Long-press a
/// message for its details, copying, mentioning or messaging its sender, sending again, or deleting it.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: ConversationID
    @State private var messages: [Message] = []
    @State private var draft = ""
    /// the people picked to mention while writing: the draft shows them "@Name", sent as "@[Name]"
    @State private var picked: [String] = []
    @State private var sendError: String?
    @State private var details: Message?
    @State private var deleting: Message?
    /// someone to block, asked about first
    @State private var blocking: BlockList.Entry?
    /// the message Block was chosen from: its dialog points there
    @State private var blockingFrom: Int64?
    @State private var confirmDeleteAll = false
    @State private var confirmLeave = false
    @State private var showRoute = false
    @State private var showRoom = false
    @State private var asking = false
    @State private var notice: String?
    /// messages loaded: the list is made only then, so it opens at the bottom
    @State private var loaded = false
    /// the newest message is in view (within 40 pt of it)
    @State private var atBottom = true
    /// the newest message you've had in view: incoming ones after it are "new"
    @State private var seenUpTo: Int64 = 0
    @State private var composing = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottom = "bottom"

    var title: String { model.title(of: conversation) }
    var limit: Int {
        if case .channel = conversation { return 150 - (model.me?.name.utf8.count ?? 0) - 2 }
        return 150
    }

    var disabledReason: String? {
        if !model.isConnected { return String(localized: "Not connected to the radio") }
        if case .listened = conversation { return String(localized: "Listening only: join the channel to send") }
        if case .direct(let k) = conversation {
            if model.contacts[k] == nil { return String(localized: "Not a contact, so it can't be messaged") }
            if let r = model.rooms[k.hex], !r.left, !RoomRole.canPost(r.role) { return String(localized: "\(RoomRole.label(r.role)): you can read this room, not post") }
        }
        return nil
    }

    var body: some View {
        dialogs(screens(list))
    }

    /// The messages, made only once they're loaded: the scroll view's first layout then has them all,
    /// and opens at the bottom (loading after the first frame and scrolling down afterwards lands short
    /// in a lazy stack, whose rows' heights are only estimated until drawn).
    private var list: some View {
        ScrollViewReader { proxy in
            ZStack {
                if loaded { scroller(proxy) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.messageVersion[conversation]) { reload(proxy) }
            .onChange(of: atBottom) { _, now in if now { markIfSeen() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { markIfSeen() } }
            .safeAreaInset(edge: .bottom) { composer }
        }
        .onAppear(perform: load)
    }

    private func scroller(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                    // where the radio moved to another network: what follows was heard (or sent) there
                    if let n = Message.networkChange(messages, at: i) { NetworkDivider(name: model.radioProfiles.name(forNetwork: n)) }
                    MessageRow(message: m, grouped: grouped(i), showSender: !isDirectPerson, mentionsMe: mentionsMe(m),
                               previews: model.linkPreviews == .everywhere || (model.linkPreviews == .direct && isDirectPerson),
                               mention: canMention ? { name in draft = Mentions.insert(name, into: draft); pick(name) } : nil)
                        .id(m.id)
                        .contextMenu { menu(for: m) }
                        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting?.id == m.id }, set: { if !$0 { deleting = nil } }),
                                            titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { if let id = m.id { Task { try? await model.engine.deleteMessage(id) } } }
                        } message: { Text("It's removed from this device only.") }
                        .confirmationDialog("Block \(blocking?.name ?? "")?", isPresented: Binding(get: { blocking != nil && blockingFrom == m.id }, set: { if !$0 { blocking = nil; blockingFrom = nil } }),
                                            titleVisibility: .visible) {
                            Button("Block", role: .destructive) {
                                if let b = blocking { model.block(name: b.name, key: b.key); reloadNow() }
                            }
                        } message: {
                            Text("Their messages are hidden on this iPhone, on channels and in direct messages, and don't notify you. They aren't told. Unblock them in Settings › Blocked.")
                        }
                }
                // the end of the list, to scroll to (and before iOS 18, to tell whether it's in view)
                Color.clear.frame(height: 1).id(Self.bottom)
                    .onAppear { if #unavailable(iOS 18, macOS 15) { atBottom = true } }
                    .onDisappear { if #unavailable(iOS 18, macOS 15) { atBottom = false } }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .modifier(BottomTracker(atBottom: $atBottom))
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(isDirectPerson ? "You'll see “delivered” when their radio confirms it." : "Messages appear as your radio hears them."))
            }
        }
        .overlay(alignment: .bottom) {
            ZStack { banner(proxy) }
                .padding(.bottom, 8)
                .animation(reduceMotion ? nil : .snappy, value: showsBanner)
                .animation(reduceMotion ? nil : .snappy, value: unseen.count)
        }
    }

    // MARK: staying at the bottom, and what's new below

    /// Incoming messages since the newest you've had in view.
    private var unseen: [Message] {
        Array(messages.reversed().prefix { ($0.id ?? 0) > seenUpTo }.filter { $0.direction == .incoming }.reversed())
    }

    private var showsBanner: Bool { !atBottom && !unseen.isEmpty }

    /// "↓ 3 new messages", above the composer while new messages are out of view; tap to go down.
    @ViewBuilder private func banner(_ proxy: ScrollViewProxy) -> some View {
        if showsBanner {
            let new = unseen
            let text = new.count == 1 ? new[0].sender.map { String(localized: "New message from \($0)") } ?? String(localized: "New message")
                : String(localized: "\(new.count) new messages")
            Button { scrollToBottom(proxy) } label: {
                Label(text, systemImage: "arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(new.count)))
            }
            .modifier(BannerStyle())
            .padding(.horizontal, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityHint("Scrolls to the newest message")
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        else { withAnimation(.snappy) { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
        // and again until it's there: in a lazy stack the rows' heights are estimates until drawn, so a long
        // scroll can stop short (or, over many rows not drawn yet, barely move)
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<8 {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(120))
                if atBottom { break }
            }
        }
    }

    /// The first load, before the list exists (on appearing, or the first `.task`, whichever comes first).
    private func load() {
        guard !loaded else { return }
        messages = shown((try? model.store.messages(in: conversation)) ?? [])
        seenUpTo = messages.last?.id ?? 0
        loaded = true
        markIfSeen()
    }

    /// Messages changed: arriving, sent, their status, deleted. A new one scrolls into view if you're at
    /// the bottom (or it's yours); otherwise the banner says so.
    private func reload(_ proxy: ScrollViewProxy) {
        guard loaded else { load(); return }
        let before = messages.last?.id ?? 0
        messages = shown((try? model.store.messages(in: conversation)) ?? [])
        guard let last = messages.last, let id = last.id, id > before else { markIfSeen(); return }
        if atBottom || last.direction == .outgoing {
            scrollToBottom(proxy)
            if last.direction == .outgoing { seenUpTo = max(seenUpTo, id) }
        } else if last.direction == .incoming {
            AccessibilityNotification.Announcement(last.sender.map { String(localized: "New message from \($0)") } ?? String(localized: "New message")).post()
        }
        markIfSeen()
    }

    /// Read: up to the newest message, when it's in view and the app is in front.
    private func markIfSeen() {
        guard atBottom, scenePhase == .active, let id = messages.last?.id else { return }
        seenUpTo = max(seenUpTo, id)
        model.markRead(conversation, upTo: id)
    }

    private func screens(_ v: some View) -> some View {
        v
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { conversationMenu } }
        // on screen: its messages don't notify, and they're read
        .onAppear { model.visibleConversation = conversation }
        .onDisappear { if model.visibleConversation == conversation { model.visibleConversation = nil } }
        .navigationDestination(isPresented: $showRoute) {
            if case .direct(let k) = conversation { RouteDetailsView(key: k) }
        }
        .sheet(isPresented: $showRoom) { if case .direct(let k) = conversation { RoomDetailsView(key: k) } }
        .sheet(isPresented: $asking) { if case .direct(let k) = conversation { NodeQueryView(key: k) } }
        .sheet(item: $details) { MessageDetailsView(message: $0) }
        .task(id: loaded) {
            guard loaded, model.demoShow == "route" else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, model.demoShow == "route" else { return }
            model.demoShow = nil
            details = messages.last { $0.direction == .incoming && ($0.hops ?? 0) >= 3 }
        }
    }

    private func dialogs(_ v: some View) -> some View {
        v
        .alert("Not sent", isPresented: .present($sendError), presenting: sendError) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .alert("Can't show the route", isPresented: .present($notice), presenting: notice) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private var isDirectPerson: Bool {
        if case .direct = conversation { return !model.isRoom(conversation) }
        return false
    }

    private func mentionsMe(_ m: Message) -> Bool {
        guard m.direction == .incoming, let me = model.me?.name else { return false }
        return m.text.contains("@[\(me)]")
    }

    private func grouped(_ i: Int) -> Bool {
        guard i > 0, Message.networkChange(messages, at: i) == nil else { return false }
        let a = messages[i - 1], b = messages[i]
        return a.direction == b.direction && a.sender == b.sender && b.date.timeIntervalSince(a.date) < 300
    }


    @ViewBuilder private func menu(for m: Message) -> some View {
        Button { details = m } label: { Label("Details", systemImage: "info.circle") }
        Button { copyToClipboard(m.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
        if m.direction == .incoming, let s = m.sender, !isDirectPerson {
            if disabledReason == nil {
                Button { draft = "@\(s) " + draft; pick(s) } label: { Label("Reply to \(s)", systemImage: "arrowshape.turn.up.left") }
            }
            if let c = model.contacts.values.first(where: { $0.name == s && $0.type == .companion }) {
                Button { model.open(.direct(c.key)) } label: { Label("Message \(s) privately", systemImage: "person.crop.circle") }
                if c.position != nil {
                    Button { model.showOnMap(c.key.hex) } label: { Label("Show \(s) on map", systemImage: "mappin.and.ellipse") }
                }
            }
        }
        if m.path?.isEmpty == false || (m.direction == .incoming && sender(of: m)?.position != nil) {
            Button { showRoute(of: m) } label: { Label("Show route on map", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
        }
        if m.direction == .outgoing, m.status == .notHeard, case .channel = m.conversation, let id = m.id, model.isConnected {
            Button { Task { try? await model.engine.resend(id) } } label: { Label("Send again", systemImage: "arrow.clockwise") }
        }
        if m.direction == .incoming, let s = m.sender, !s.isEmpty {
            let key: String? = if case .direct(let k) = conversation, isDirectPerson { k.hex } else { sender(of: m)?.key.hex }
            Button(role: .destructive) { blocking = BlockList.Entry(name: s, key: key); blockingFrom = m.id } label: { Label("Block \(s)…", systemImage: "hand.raised") }
        }
        Divider()
        Button(role: .destructive) { deleting = m } label: { Label("Delete", systemImage: "trash") }
    }

    private func reloadNow() { messages = shown((try? model.store.messages(in: conversation)) ?? []) }

    /// Without blocked people's messages.
    private func shown(_ all: [Message]) -> [Message] { all.filter { !model.blockList.hides($0) } }

    /// Who sent it, as a contact: the other side of a DM, or the person of that name in a channel.
    private func sender(of m: Message) -> Contact? {
        if case .direct(let k) = conversation { return model.contacts[k] }
        guard let s = m.sender else { return nil }
        return model.contacts.values.first { $0.name == s && $0.type == .companion }
    }

    private func showRoute(of m: Message) {
        let r = MapRoute.of(m, directory: model.directory, sender: m.direction == .incoming ? sender(of: m) : nil)
        if r.isDrawable { model.showRoute(r) }
        else if model.home == nil {
            notice = String(localized: "None of the \(r.hops) repeaters on this route has a known position, and your home location isn't set, so there's nothing to draw.")
        } else {
            notice = String(localized: "None of the \(r.hops) repeaters on this route has a known position, so there's nothing to draw.")
        }
    }

    private var conversationMenu: some View {
        Menu {
            switch conversation {
            case .direct(let k):
                if model.isRoom(conversation) {
                    Button { showRoom = true } label: { Label("Room details", systemImage: "info.circle") }
                } else {
                    Button { showRoute = true } label: { Label("Route details", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    if let title = model.contacts[k]?.type.queryTitle {
                        Button { asking = true } label: { Label(title, systemImage: "gauge.with.dots.needle.33percent") }
                    }
                }
                if model.contacts[k]?.position != nil {
                    Button { model.showOnMap(k.hex) } label: { Label("Show on map", systemImage: "map") }
                }
            case .channel:
                Button(role: .destructive) { confirmLeave = true } label: { Label("Leave channel…", systemImage: "rectangle.portrait.and.arrow.right") }
            case .listened(let name):
                Button(role: .destructive) {
                    Task { try? await model.engine.stopListening(to: name); dismiss() }
                } label: { Label("Stop listening", systemImage: "ear.badge.waveform") }
            }
            NotifyMenu(conversation: conversation)
            Divider()
            Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete messages…", systemImage: "trash") }
                .disabled(messages.isEmpty)
        } label: { Label("More", systemImage: "ellipsis.circle") }
            .confirmationDialog("Leave \(title)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave channel", role: .destructive) { leave() }
            } message: { Text("It frees the radio's channel slot and deletes its messages from this iPhone. You can join again with the same name or secret.") }
            .confirmationDialog("Delete every message in \(title)?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete \(messages.count) messages", role: .destructive) {
                    Task { _ = try? await model.engine.deleteConversation(conversation) }
                }
            } message: { Text("They're removed from this device only. The conversation stays, and new messages still arrive.") }
    }

    private func leave() {
        guard case .channel(let i) = conversation else { return }
        Task {
            do { try await model.delete(.channel(i)); dismiss() } catch { sendError = "\(error)" }
        }
    }

    /// Mentions are for channels and rooms you can write in (a DM is already to one person).
    private var canMention: Bool { disabledReason == nil && !isDirectPerson }

    /// Who wrote here lately, newest first: the first people to suggest for a mention.
    private var recentSenders: [String] {
        messages.suffix(300).reversed().compactMap { $0.direction == .incoming ? $0.sender : nil }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let disabledReason {
                Text(disabledReason).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                if canMention, let query = Mentions.typing(in: draft, picked: picked) {
                    mentionSuggestions(query)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    MessageField(placeholder: isDirectPerson ? String(localized: "Message \(title) privately") : String(localized: "Message \(title)"),
                                 text: $draft, picked: picked, focused: $composing, onSubmit: send)
                        .modifier(ComposerField())
                    SendButton(disabled: outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bytes > limit, send: send)
                }
                if bytes > limit - 30 {
                    Text("\(bytes)/\(limit)").font(.caption2.monospacedDigit())
                        .foregroundStyle(bytes > limit ? .red : .secondary)
                        .accessibilityLabel("\(bytes) of \(limit) bytes")
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .modifier(ComposerBackground())
    }

    /// The draft as it's sent: picked mentions in MeshCore's "@[Name]".
    private var outgoing: String { Mentions.wire(draft, picked: picked) }
    private var bytes: Int { outgoing.utf8.count }

    /// Someone mentioned in the draft: shown "@Name", sent "@[Name]".
    private func pick(_ name: String) {
        if !picked.contains(name) { picked.append(name) }
        composing = true
    }

    /// People to mention for what's typed after "@": tap one for "@Name ".
    @ViewBuilder private func mentionSuggestions(_ query: String) -> some View {
        let names = Mentions.suggestions(for: query, recent: recentSenders,
                                         others: model.contacts.values.filter { $0.type == .companion }.map(\.name), me: model.me?.name)
        if !names.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Button { draft = Mentions.complete(draft, with: name); pick(name) } label: {
                            Text("@" + name).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Mention \(name)")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollClipDisabled()
        } else if !query.isEmpty {
            Text("Nobody called “\(query)” here or in your contacts").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= limit else { return }
        let (was, names) = (draft, picked)
        draft = ""; picked = []
        Task {
            do { _ = try await model.engine.send(text, to: conversation) }
            catch { draft = was; picked = names; sendError = "\(error)" }
        }
    }
}

/// The message field: a floating glass field on iOS 26 and later (as in Messages), a rounded field
/// on a bar before that.
private struct ComposerField: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            content.padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        } else {
            content.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(uiColor: .separator)))
        }
        #else
        content.textFieldStyle(.roundedBorder)
        #endif
    }
}

/// Whether the end of the list is in view (within 40 pt), from the scroll view's geometry on iOS 18 and
/// later; before that the end-of-list marker's appearing and disappearing tells.
private struct BottomTracker: ViewModifier {
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                // the bottom of what you can see: the visible rect runs under the bars, so less the bottom
                // inset (the composer and tab bar). Not offset + container size: on iOS 26 and later the
                // container size already leaves the insets out, so that came up short by the bars' height
                // and never counted as the bottom.
                g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 40
            } action: { _, now in
                atBottom = now
            }
        } else {
            content
        }
    }
}

/// The "new messages" pill: tinted glass on iOS 26 and later, an accent capsule before that.
private struct BannerStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            capsule(content)
        }
        #else
        capsule(content)
        #endif
    }

    private func capsule(_ content: Content) -> some View {
        content.buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.accentColor, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

private struct ComposerBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) { content } else { content.background(.bar) }
        #else
        content.background(.bar)
        #endif
    }
}

private struct SendButton: View {
    let disabled: Bool
    let send: () -> Void

    var body: some View {
        Group {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 26, *) {
                Button(action: send) { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 24, height: 24) }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
            }
            #else
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
            #endif
        }
        .disabled(disabled)
        .accessibilityLabel("Send")
        .keyboardShortcut(.return, modifiers: .command)
    }
}

/// One message: a bubble (ours on the right), the sender above a group, and its details below.
struct MessageRow: View {
    let message: Message
    let grouped: Bool
    let showSender: Bool
    var mentionsMe = false
    /// a link's preview in the message's bubble: nil for none, true to load it without being asked
    var previews: Bool? = nil
    /// set where you can write: tapping the sender's name mentions them
    var mention: ((String) -> Void)? = nil

    var outgoing: Bool { message.direction == .outgoing }

    var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
            if !grouped && !outgoing && showSender, let s = message.sender {
                Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                    .contentShape(.rect)
                    .onTapGesture { mention?(s) }
            }
            bubble
            meta
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .padding(outgoing ? .leading : .trailing, 48)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Touch and hold for options")
        .accessibilityActions {
            if let mention, !outgoing, showSender, let s = message.sender {
                Button("Mention \(s)") { mention(s) }
            }
        }
    }

    /// The bubble. A message with a link has the link's preview on top, in the same bubble as its text, as
    /// in Messages; one that's nothing but the link is just the preview, once that has loaded.
    @ViewBuilder private var bubble: some View {
        #if os(iOS)
        if let previews, let link = Links.find(in: message.text).first(where: { Links.fetchable($0.url) }) {
            let onlyLink = message.text[link.range].count == message.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            VStack(alignment: .leading, spacing: 0) {
                LinkPreviewCard(url: link.url, auto: previews, outgoing: outgoing)
                if !(onlyLink && LinkPreviews.shared.isLoaded(link.url)) { text.frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxWidth: 260)
            .background(outgoing ? Color.accentColor : Color.incomingBubble)
            .clipShape(.rect(cornerRadius: 16))
            .overlay { if mentionsMe { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .foregroundStyle(outgoing ? .white : .primary)
        } else {
            plainBubble
        }
        #else
        plainBubble
        #endif
    }

    private var plainBubble: some View {
        text
            .background(outgoing ? Color.accentColor : Color.incomingBubble, in: .rect(cornerRadius: 16))
            .overlay { if mentionsMe { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .foregroundStyle(outgoing ? .white : .primary)
    }

    private var text: some View {
        Text(Self.styled(message.text, outgoing: outgoing))
            .tint(outgoing ? .white : .accentColor)   // links: tappable, underlined
            .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// Mentions ("@[name]", as MeshCore apps write them) as a bold, tinted @name, and web links as links.
    static func styled(_ text: String, outgoing: Bool) -> AttributedString {
        var out = mentionsStyled(text, outgoing: outgoing)
        let plain = String(out.characters)
        for link in Links.find(in: plain) {
            guard let range = Range(link.range, in: out) else { continue }
            out[range].link = link.url
            out[range].underlineStyle = .single
        }
        return out
    }

    private static func mentionsStyled(_ text: String, outgoing: Bool) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "@["), let close = rest[open.upperBound...].firstIndex(of: "]") {
            out += AttributedString(rest[..<open.lowerBound])
            var mention = AttributedString("@" + rest[open.upperBound..<close])
            mention.font = .body.weight(.semibold)
            if !outgoing { mention.foregroundColor = .accentColor }
            out += mention
            rest = rest[rest.index(after: close)...]
        }
        return out + AttributedString(rest)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if Calendar.current.isDateInToday(message.date) { Text(message.date, style: .time) }
            else { Text(message.date, format: .dateTime.day().month(.abbreviated).hour().minute()) }
            if !outgoing, let h = message.hops { Text(h == 0 ? "direct" : h == 1 ? "1 hop" : "\(h) hops") }
            if !outgoing, let snr = message.snr { Text(String(format: "%.1f dB", snr)) }
            if outgoing { status }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var status: some View {
        switch message.status {
        case .sending: Label("sending", systemImage: "clock")
        case .sent: Label(message.attempts > 1 ? "sent · try \(message.attempts)" : "sent", systemImage: "checkmark")
        case .repeated: Label("repeated ×\(message.repeats)", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .notHeard: Label("not heard · \(message.attempts) tries", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .delivered: Label(message.ackTry.map { $0 > 1 ? String(localized: "delivered · try \($0)") : String(localized: "delivered") } ?? String(localized: "delivered"),
                               systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .noAck: Label("no receipt", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .failed: Label("failed", systemImage: "xmark.circle").foregroundStyle(.red)
        case .received: EmptyView()
        }
    }
}

extension Color {
    /// Incoming message bubbles: light grey in light mode (as before), and in dark mode a grey lifted
    /// well off the black background, which a translucent overlay left too dark to read as a bubble.
    static let incomingBubble: Color = {
        #if os(iOS)
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.21, alpha: 1)                              // ≈ #363636
                : UIColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1)    // ≈ #E9E9EB
        })
        #else
        Color.secondary.opacity(0.15)
        #endif
    }()
}

/// A line across the timeline where the radio moved to another network.
struct NetworkDivider: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Label("On \(name)", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network changed to \(name)")
    }
}
