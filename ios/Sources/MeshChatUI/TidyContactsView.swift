import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Removing contacts from the radio in bulk: the kinds you pick, further than a number of hops away and/or
/// not heard for a while.
/// Favourites, rooms you've joined, anyone you have messages with and your repeater always stay, and the
/// app keeps what it heard of the rest (they stay in Nodes and on the map).
struct TidyContactsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kinds: Set<NodeType> = ContactTidy.Options.standard.kinds
    @State private var age: ContactTidy.Age = ContactTidy.Options.standard.age
    @State private var beyondHops: Int? = ContactTidy.Options.standard.beyondHops
    @State private var yours: String?
    /// the kinds the radio adds by itself (nil: not known yet)
    @State private var autoAdded: Set<NodeType>?
    /// how far the radio adds new nodes from (nil: not known yet)
    @State private var autoAdd: AutoAddConfig?
    @State private var limiting = false
    @State private var confirm = false
    @State private var confirmAll = false
    @State private var run = TidyRun()

    var body: some View {
        let plan = model.contactTidy(ContactTidy.Options(kinds: kinds, age: age, beyondHops: beyondHops), yourRepeater: yours)
        NavigationStack {
            Form {
                ConnectionNoticeSection()
                if let d = model.device {
                    let f = ContactTidy.fullness(count: model.contacts.count, max: d.maxContacts)
                    Section {
                        LabeledContent("Contacts on the radio") {
                            Text(f.text).monospacedDigit().foregroundStyle(f.nearlyFull ? .orange : .secondary)
                        }
                    } footer: {
                        Text("When it's full, the radio stops adding nodes it hears, unless it makes room (Mesh behaviour).")
                    }
                }
                Section {
                    kindToggle("Repeaters", .repeater)
                    kindToggle("Sensors", .sensor)
                    kindToggle("People", .companion)
                    kindToggle("Rooms", .room)
                    Picker("Distance", selection: $beyondHops) {
                        ForEach(ContactTidy.Options.hopChoices, id: \.self) { n in
                            Text(n.map { $0 == 1 ? String(localized: "More than 1 hop") : String(localized: "More than \($0) hops") } ?? String(localized: "Any distance")).tag(n)
                        }
                    }
                    Picker("Last heard", selection: $age) {
                        ForEach(ContactTidy.Age.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: { Text("Remove") } footer: {
                    Text("Hops: how many repeaters its adverts pass through to reach you, as last heard.")
                }
                .disabled(run.active)
                kept(plan)
                action(plan)
                limitSection
                clearAllSection
            }
            .formStyle(.grouped)
            .navigationTitle("Tidy contacts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.finished ? "Done" : "Cancel") { dismiss() }.disabled(run.active)
                }
            }
            .confirmationDialog(plan.actionTitle + "?", isPresented: $confirm, titleVisibility: .visible) {
                Button(plan.actionTitle, role: .destructive) { start(plan) }
            } message: {
                Text("The radio forgets them and their saved routes. Messages and what the app heard stay.")
            }
        }
        .interactiveDismissDisabled(run.active)
        .task { yours = await model.repeaterAnalysis(days: 7).yours?.key }
        .task(id: model.isConnected) { await loadAutoAdd() }
    }

    private func kindToggle(_ title: LocalizedStringKey, _ type: NodeType) -> some View {
        Toggle(title, isOn: Binding(get: { kinds.contains(type) }, set: { on in if on { kinds.insert(type) } else { kinds.remove(type) } }))
    }

    @ViewBuilder private func kept(_ plan: ContactTidy) -> some View {
        Section {
            keepRow("Favourites", "star", plan.kept[.favourite])
            keepRow("Rooms you've joined", "door.left.hand.open", plan.kept[.joinedRoom])
            keepRow("Anyone you have messages with", "bubble.left.and.bubble.right", plan.kept[.messaged])
            keepRow("Your repeater", "antenna.radiowaves.left.and.right", plan.kept[.yourRepeater])
            keepRow("Heard lately", "waveform", plan.kept[.heardLately])
            keepRow(beyondHops.map { $0 == 1 ? "Within 1 hop" : "Within \($0) hops" } ?? "Near", "scope", plan.kept[.near])
            keepRow("Distance not known yet", "questionmark.circle", plan.kept[.distanceUnknown])
            keepRow("Other kinds", "circle.dashed", plan.kept[.otherKind])
        } header: {
            Text("Keeps \(plan.keptCount)")
        } footer: {
            Text("Favourites, rooms you've joined, anyone you have messages with and your repeater are always kept. Star a contact in Nodes to keep it.")
        }
    }

    @ViewBuilder private func keepRow(_ title: LocalizedStringKey, _ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            LabeledContent { Text("\(count)").monospacedDigit() } label: { Label(title, systemImage: symbol) }
        }
    }

    @ViewBuilder private func action(_ plan: ContactTidy) -> some View {
        Section {
            if run.active {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(run.done), total: Double(max(run.target, 1)))
                    Text("Removed \(run.done) of \(run.target)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Stop", role: .destructive) { run.task?.cancel() }
            } else {
                if let result = run.result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.ok ? Color.primary : .orange)
                }
                Button(plan.actionTitle, role: .destructive) { confirm = true }
                    .disabled(plan.remove.isEmpty || !model.isConnected)
            }
        } footer: {
            Text(footer(plan))
        }
    }

    private func footer(_ plan: ContactTidy) -> String {
        var s = String(localized: "Longest unheard first. They stay in Nodes and on the map, and you can add one back from there.")
        let returning = kinds.intersection(autoAdded ?? [])
        if !plan.remove.isEmpty, !returning.isEmpty {
            let names = returning.map { t -> String in
                switch t {
                case .companion: String(localized: "people")
                case .repeater: String(localized: "repeaters")
                case .room: String(localized: "rooms")
                case .sensor: String(localized: "sensors")
                case .unknown: String(localized: "other nodes")
                }
            }.sorted().formatted(.list(type: .and))
            s += " " + String(localized: "Your radio adds \(names) it hears by itself, so they come back with their next advert. Choose what it adds in Mesh behaviour.")
        }
        return s
    }

    private func start(_ plan: ContactTidy) { start(plan.remove.map(\.key)) }

    private func start(_ keys: [PublicKey]) {
        let run = run, model = model
        run.start(keys.count)
        run.task = Task {
            do {
                let n = try await model.engine.removeContacts(keys) { n in await run.progress(n) }
                run.finish(n == keys.count ? String(localized: "Removed \(n).") : String(localized: "Stopped after removing \(n) of \(keys.count)."), ok: true)
            } catch {
                run.finish(String(localized: "Stopped after removing \(run.done) of \(keys.count): \(String(describing: error))"), ok: false)
            }
            if run.done > 0 { model.contactsFullNotice = false }
        }
    }

    /// Clearing the list: every contact, or all but favourites. People and rooms too, so it says what
    /// that costs.
    @ViewBuilder private var clearAllSection: some View {
        let total = model.contacts.count
        let favourites = model.contacts.values.filter(\.isFavourite).count
        Section {
            Button(role: .destructive) { confirmAll = true } label: { Text("Remove all \(total) contacts…") }
                .disabled(total == 0 || !model.isConnected || run.active)
        } header: {
            Text("Clear the list")
        } footer: {
            Text("Every contact, people and rooms too. You can't message someone again until their next advert adds them back, and rooms need joining again. The app keeps what it heard: they stay in Nodes and on the map.")
        }
        .confirmationDialog("Remove contacts from the radio?", isPresented: $confirmAll, titleVisibility: .visible) {
            if favourites > 0 {
                Button(favourites == 1 ? "Remove all but 1 favourite" : "Remove all but \(favourites) favourites", role: .destructive) {
                    start(model.allContacts(keepFavourites: true).map(\.key))
                }
            }
            Button("Remove all \(total)", role: .destructive) { start(model.allContacts(keepFavourites: false).map(\.key)) }
        } message: {
            Text("The radio forgets them, their routes and its logins to rooms and repeaters. Messages stay on this iPhone.")
        }
    }

    /// After removing far ones: stop the radio adding them again with their next advert.
    @ViewBuilder private var limitSection: some View {
        if let n = beyondHops, let a = autoAdd, a.reachHops.map({ $0 > n }) ?? true {
            Section {
                Button {
                    Task { await limit(to: n) }
                } label: {
                    Label(n == 1 ? "Add new nodes only up to 1 hop away" : "Add new nodes only up to \(n) hops away", systemImage: "scope")
                }
                .disabled(limiting || run.active || !model.isConnected)
            } footer: {
                let reach = a.reachHops.map {
                    $0 == 0 ? String(localized: "Your radio adds new nodes heard directly, so far ones come back with their next advert.")
                        : String(localized: "Your radio adds new nodes heard up to \($0) hops away, so far ones come back with their next advert.")
                } ?? String(localized: "Your radio adds new nodes heard at any distance, so far ones come back with their next advert.")
                Text(reach + " " + String(localized: "The limit counts for every node it adds by itself, people too (Mesh behaviour › From)."))
            }
        }
    }

    private func limit(to hops: Int) async {
        guard var a = autoAdd else { return }
        limiting = true; defer { limiting = false }
        a.maxHops = AutoAddConfig.maxHops(forReach: hops)
        do { try await model.engine.setAutoAdd(a); autoAdd = try await model.engine.autoAdd() }
        catch { run.finish(String(localized: "Not changed: \(String(describing: error))"), ok: false) }
    }

    private func loadAutoAdd() async {
        guard model.isConnected, let other = model.me?.otherParams else { return }
        let a = try? await model.engine.autoAdd()
        autoAdd = a
        if other.manualAddContacts & 1 == 0 { autoAdded = [.companion, .repeater, .room, .sensor]; return }
        guard let a else { return }
        let flags: [(NodeType, UInt8)] = [(.companion, AutoAddConfig.people), (.repeater, AutoAddConfig.repeaters),
                                           (.room, AutoAddConfig.rooms), (.sensor, AutoAddConfig.sensors)]
        autoAdded = Set(flags.filter { a.has($0.1) }.map(\.0))
    }
}

/// A tidy in progress: how far it got, and how it ended.
@MainActor @Observable
final class TidyRun {
    var done = 0
    var target = 0
    var active = false
    var result: (text: String, ok: Bool)?
    var task: Task<Void, Never>?
    var finished: Bool { result != nil }

    func start(_ n: Int) { target = n; done = 0; active = true; result = nil }
    func progress(_ n: Int) { done = n }
    func finish(_ text: String, ok: Bool) { result = (text, ok); active = false; task = nil }
}
