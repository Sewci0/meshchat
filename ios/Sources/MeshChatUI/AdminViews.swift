import MeshChatCore
import MeshCoreKit
import SwiftUI

/// A command waiting for "are you sure?".
private struct PendingCommand: Identifiable {
    let command: String
    let title: String
    let message: String
    var id: String { command }
}

/// A repeater's (or room server's) admin commands, as sections of its detail form: log in with the
/// admin password, then actions, settings (read and change), and its command line with every command.
struct AdminSections: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var password = ""
    @State private var loggingIn = false
    @State private var answer: LiveAnswer?
    @State private var problem: String?
    @State private var command = ""
    @State private var pending: PendingCommand?
    @State private var editing: AdminSetting?
    @State private var draft = ""
    @FocusState private var typing: Bool

    static let quick = ["reboot", "advert", "advert.zerohop", "clock sync", "clock", "ver", "power", "neighbors", "discover.neighbors", "clear stats"]
        .compactMap { c in AdminCommand.all.first { $0.command == c } }

    var pk: PublicKey? { PublicKey(hex: key) }
    var lines: [ConsoleLine] { pk.flatMap { model.consoles[$0] } ?? [] }
    var isAdmin: Bool { answer?.ok == true && answer?.admin == true }

    var body: some View {
        let answers = AdminConsole.answers(lines), values = AdminConsole.values(lines)
        login
        if isAdmin {
            Section("Actions") {
                ForEach(Self.quick) { c in
                    Button { ask(c) } label: {
                        Label(c.label, systemImage: c.confirm == nil ? "play.circle" : "exclamationmark.triangle")
                    }
                    .disabled(!model.isConnected)
                }
            }
            ForEach(["Node", "Radio", "Access"], id: \.self) { g in
                Section(groupTitle(g)) {
                    ForEach(AdminSetting.all.filter { $0.group == g }) { s in setting(s, value: values[s.name]) }
                }
            }
            console(answers)
        }
    }

    /// a settings group's heading (the group itself stays as AdminSetting names it)
    private func groupTitle(_ g: String) -> String {
        switch g {
        case "Node": String(localized: "Node")
        case "Radio": String(localized: "Radio")
        case "Access": String(localized: "Access")
        default: g
        }
    }

    // MARK: login

    @ViewBuilder private var login: some View {
        Section {
            if isAdmin, let a = answer {
                Label("Logged in as admin \(a.date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            }
            SecureField("Admin password", text: $password)
                .textContentType(.password)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await logIn() } }
            Button { Task { await logIn() } } label: {
                if loggingIn { HStack { ProgressView(); Text("Logging in… 5–30 s") } }
                else { Text(isAdmin ? "Log in again" : "Log in as admin") }
            }
            .disabled(loggingIn || password.isEmpty || !model.isConnected || pk.flatMap { model.contacts[$0] } == nil)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: {
            Text("Admin")
        } footer: {
            Text(isAdmin
                 ? "Commands go to it one at a time; answers take 5–30 s. If one gets no answer, the repeater may have forgotten the login: log in again."
                 : "Admin commands need the repeater's admin password. MeshChat sends it to the repeater to log in and doesn't keep it.")
        }
        .task(id: model.routeVersion) { answer = try? model.store.liveAnswer(key) }
    }

    private func logIn() async {
        guard let pk, !password.isEmpty else { return }
        loggingIn = true; defer { loggingIn = false }
        let pwd = password
        password = ""   // not kept
        problem = nil
        do {
            let a = try await model.engine.query(pk, password: pwd)
            answer = a
            if !a.ok { problem = a.error ?? String(localized: "No answer.") }
            else if !a.admin {
                problem = a.role.map { String(localized: "That password logs in as \($0), not admin.") }
                    ?? String(localized: "That password logs in as a guest, not admin.")
            }
        } catch { problem = "\(error)" }
    }

    // MARK: settings

    private func setting(_ s: AdminSetting, value: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label)
                Text(value ?? String(localized: "not read")).font(.callout.monospaced()).foregroundStyle(value == nil ? .secondary : .primary).lineLimit(1)
                Text(s.name + (s.hint.isEmpty ? "" : " · \(s.hint)")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Read") { run("get \(s.name)") }.buttonStyle(.borderless)
            Menu("Change") {
                if let options = s.options {
                    ForEach(options, id: \.self) { o in Button(o) { set(s, o) } }
                } else {
                    Button("Type a new value…") { draft = s.isSecret ? "" : value ?? ""; editing = s }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(!model.isConnected)
        .alert(s.label, isPresented: .init(get: { editing == s }, set: { if !$0 { editing = nil } })) {
            if s.isSecret { SecureField(s.hint, text: $draft) } else { TextField(s.hint, text: $draft).autocorrectionDisabled() }
            Button("Cancel", role: .cancel) {}
            Button("Set") { set(s, draft.trimmingCharacters(in: .whitespaces)) }
        } message: { Text("Sends set \(s.name) to the repeater.") }
    }

    private func set(_ s: AdminSetting, _ value: String) {
        let c = "set \(s.name) \(value)"
        if let confirm = s.confirm { pending = PendingCommand(command: c, title: String(localized: "Change \(s.label.lowercased())?"), message: confirm) }
        else { run(c) }
    }

    // MARK: command line

    private func console(_ answers: [Int: ConsoleLine]) -> some View {
        Section {
            if lines.isEmpty { Text("Commands you send and the repeater's answers appear here.").foregroundStyle(.secondary) }
            ForEach(lines) { l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if l.isCommand { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    Text(l.text).font(.callout.monospaced()).foregroundStyle(l.isCommand ? .primary : .secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if l.isCommand {
                        if l.status == .failed { Text("not sent").font(.caption).foregroundStyle(.red) }
                        else if answers[l.id] == nil { ProgressView().controlSize(.mini).accessibilityLabel("Waiting for the answer") }
                    }
                }
                .padding(.leading, l.isCommand ? 0 : 16)
            }
            HStack {
                TextField("A command, e.g. get radio", text: $command)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button("Send", action: sendTyped).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || !model.isConnected)
            }
            NavigationLink {
                AdminCommandList { c in
                    if c.needsValue { command = c.command; typing = true } else { ask(c) }
                }
            } label: {
                LabeledContent("All commands", value: "\(AdminCommand.all.count)")
            }
        } header: {
            Text("Command line")
        }
        .confirmationDialog(pending?.title ?? "", isPresented: .present($pending), titleVisibility: .visible, presenting: pending) { p in
            Button("Send", role: .destructive) { run(p.command) }
        } message: { p in Text(p.message) }
    }

    private func sendTyped() {
        let t = command.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        command = ""
        if let c = AdminCommand.matching(t), let confirm = c.confirm { pending = PendingCommand(command: t, title: "\(c.label)?", message: confirm) }
        else { run(t) }
    }

    private func ask(_ c: AdminCommand) {
        if let confirm = c.confirm { pending = PendingCommand(command: c.command, title: "\(c.label)?", message: confirm) }
        else { run(c.command) }
    }

    private func run(_ c: String) {
        guard let pk else { return }
        let e = model.engine
        Task { await e.runCommand(c, on: pk) }
    }
}

/// Every command the repeater takes remotely, by group, searchable. Tapping one sends it, or puts it in
/// the command field when it needs a value.
struct AdminCommandList: View {
    @Environment(\.dismiss) private var dismiss
    let use: (AdminCommand) -> Void
    @State private var query = ""

    var body: some View {
        let shown = AdminCommand.all.filter { c in query.isEmpty || "\(c.command) \(c.label) \(c.about)".localizedCaseInsensitiveContains(query) }
        List {
            ForEach(AdminCommand.groups.filter { g in shown.contains { $0.group == g } }, id: \.self) { g in
                Section(g) {
                    ForEach(shown.filter { $0.group == g }) { c in
                        Button { dismiss(); use(c) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(c.label).foregroundStyle(.primary)
                                    if c.confirm != nil { Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).accessibilityLabel("Asks first") }
                                }
                                Text(c.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(c.about).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search commands")
        .navigationTitle("All commands")
        .overlay { if shown.isEmpty { ContentUnavailableView.search(text: query) } }
    }
}
