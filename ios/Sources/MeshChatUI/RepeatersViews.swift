import MeshChatCore
import MeshCoreKit
import SwiftUI

/// Every repeater that carried traffic you heard, worked out from the packet log: heard directly, or
/// further along the mesh. Your repeater first, with a warning when it has gone quiet.
struct RepeatersView: View {
    @Environment(AppModel.self) private var model
    @State private var analysis: RepeaterAnalysis?
    @AppStorage("repeatersDays") private var days = 7
    @AppStorage("repeatersShow") private var show: RepeaterFilter = .all
    @AppStorage("repeatersSort") private var sort: RepeaterSort = .relayed
    @State private var query = ""
    /// a repeater's key opens its page; a new reach-check answerer, what's known of it
    @State private var path = NavigationPath()

    var body: some View {
        let list = (analysis?.list ?? []).filter { s in (query.isEmpty || s.name.localizedCaseInsensitiveContains(query)) && show.keeps(s) }
            .sorted(by: sort.inOrder)
        // your repeater first in its list, tagged rather than shown twice
        let yours = analysis?.yours
        let pinned = list.filter { $0.key == yours?.key } + list.filter { $0.key != yours?.key }
        let direct = pinned.filter(\.direct), further = pinned.filter { !$0.direct }
        NavigationStack(path: $path) {
            List {
                if let a = analysis {
                    // (a card per network: its result and wait are that network's)
                    if query.isEmpty { ReachCard(analysis: a, network: model.network).id(model.network ?? "") }
                    if !direct.isEmpty { Section("Heard directly · \(direct.count)") { ForEach(direct) { s in NavigationLink(value: s.key) { row(s, yours: yours) } } } }
                    if !further.isEmpty { Section("Further along the mesh · \(further.count)") { ForEach(further) { s in NavigationLink(value: s.key) { row(s, yours: yours) } } } }
                }
            }
            .searchable(text: $query, prompt: "Search repeaters")
            .tabTitle("Repeaters")
            .navigationDestination(for: String.self) { key in
                if let a = analysis { RepeaterDetailView(analysis: a, key: key) } else { ProgressView() }
            }
            .navigationDestination(for: NewRepeaterAnswer.self) { NewRepeaterView(answer: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Period", selection: $days) {
                            Text("Last 24 hours").tag(1); Text("Last 7 days").tag(7); Text("Last 30 days").tag(30)
                        }
                        Picker("Show", selection: $show) {
                            ForEach(RepeaterFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Picker("Sort by", selection: $sort) {
                            ForEach(RepeaterSort.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("Filter and sort", systemImage: show == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .overlay {
                if analysis == nil {
                    ProgressView("Working out the repeaters…")
                } else if analysis?.stats.isEmpty ?? true {
                    ContentUnavailableView("Nothing heard yet", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Repeaters appear as your radio hears packets they passed on."))
                } else if list.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No repeaters match", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text(noneMatch))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .task(id: "\(days)/\(model.packetVersion / 25)") { await analyse() }
            .onAppear(perform: focusRequested)
            .onChange(of: model.repeaterFocus) { focusRequested() }
        }
    }

    /// "None of the repeaters heard in the last 7 days is heard directly.": a whole sentence for each
    /// period and filter, so each can be translated as one
    private var noneMatch: String {
        switch show {
        case .all: days == 1 ? String(localized: "None of the repeaters heard in the last 24 hours is all.")
            : String(localized: "None of the repeaters heard in the last \(days) days is all.")
        case .direct: days == 1 ? String(localized: "None of the repeaters heard in the last 24 hours is heard directly.")
            : String(localized: "None of the repeaters heard in the last \(days) days is heard directly.")
        case .further: days == 1 ? String(localized: "None of the repeaters heard in the last 24 hours is further along the mesh.")
            : String(localized: "None of the repeaters heard in the last \(days) days is further along the mesh.")
        case .contacts: days == 1 ? String(localized: "None of the repeaters heard in the last 24 hours is contacts.")
            : String(localized: "None of the repeaters heard in the last \(days) days is contacts.")
        case .located: days == 1 ? String(localized: "None of the repeaters heard in the last 24 hours is on the map.")
            : String(localized: "None of the repeaters heard in the last \(days) days is on the map.")
        }
    }

    private func focusRequested() {
        if let k = model.repeaterFocus { path = NavigationPath([k]); model.repeaterFocus = nil }
    }

    private func analyse() async { analysis = await model.repeaterAnalysis(days: days) }

    private func row(_ s: RepeaterAnalysis.Summary, yours: (key: String, passesYours: Bool, passed: Int)?) -> some View {
        let isYours = s.key == yours?.key
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.name).lineLimit(1)
                if isYours { YoursTag() }
                if s.uncertainShare > 0.3 { Text("(?)").foregroundStyle(.secondary).accessibilityLabel("ID shared with other repeaters") }
                Spacer()
                // the typical (median) signal of what you heard from it, not one answer's: an arrow down, as
                // in the reach check's "you hear it"
                if let snr = s.snrMedian {
                    Text(String(format: "↓ %.1f dB", snr)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "typical signal \(snr, specifier: "%.1f") decibels"))
                }
                HeardBadge(lastDirect: s.lastDirect)
            }
            Text([String(localized: "\(s.relayed) passed on"), s.firstHop > 0 ? String(localized: "\(s.firstHop) entered here") : nil, s.km.map { String(format: "%.1f km", $0) },
                  s.lastSeen == .distantPast ? nil : s.lastSeen.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            // why it's yours
            if isYours, let y = yours {
                Text(y.passed == 1 ? "One of your messages entered the mesh through it" : "\(y.passed) of your messages entered the mesh through it")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// How recently a repeater was heard straight from it: a symbol and the time (shape and words, not
/// colour alone).
struct HeardBadge: View {
    let lastDirect: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let f = Freshness(lastDirect: lastDirect, now: t.date)
            HStack(spacing: 3) {
                switch f {
                case .live: Image(systemName: "circle.fill").foregroundStyle(.green)
                case .recent: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.yellow)
                case .stale: Image(systemName: "circle").foregroundStyle(.secondary)
                case .never: EmptyView()
                }
                Text(lastDirect.map { Self.short($0, now: t.date) } ?? String(localized: "via mesh")).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lastDirect.map { String(localized: "Heard directly \($0.formatted(.relative(presentation: .named, unitsStyle: .wide)))") }
                                ?? String(localized: "Only heard through other repeaters"))
        }
    }

    /// "now", "4 min", "3 h", "2 d"
    static func short(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        return s < 60 ? String(localized: "now") : s < 3600 ? String(localized: "\(Int(s / 60)) min")
            : s < 86400 ? String(localized: "\(Int(s / 3600)) h") : String(localized: "\(Int(s / 86400)) d")
    }

    /// Under a minute ago, which `short` gives as "now" (asked of the time, not the words, which are translated).
    static func isNow(_ d: Date, now: Date) -> Bool { now.timeIntervalSince(d) < 60 }
}

/// At the top of Repeaters: how many you hear directly right now, and a check of which hear you. The
/// check broadcasts "who hears me?" (repeaters in range answer, if their firmware does), then pings the
/// repeaters you hear directly that stayed quiet (every repeater answers a ping). One section: a status
/// row (what's known, or the check's headline), a row per repeater, and the button.
struct ReachCard: View {
    @Environment(AppModel.self) private var model
    let analysis: RepeaterAnalysis
    @State private var step: String?
    @State private var result: ReachCheck?
    @State private var problem: String?
    /// repeaters being pinged by hand, and those resting 10 s after (each ping is airtime)
    @State private var pinging: Set<String> = []
    @State private var resting: Set<String> = []
    @State private var showAllQuiet = false
    @State private var showInfo = false
    /// when the reach check last went out on this network
    @AppStorage private var lastCheck: Double
    @ScaledMetric(relativeTo: .headline) private var iconWidth: CGFloat = 28

    /// quiet rows shown before "N more didn't answer"
    private static let quietShown = 3

    /// - network: the radio's (the wait between checks is per network: each is its own airtime)
    /// - result: a check to show from the start (previews and tests)
    init(analysis: RepeaterAnalysis, network: String?, result: ReachCheck? = nil) {
        self.analysis = analysis
        _result = State(initialValue: result)
        _lastCheck = AppStorage(wrappedValue: 0, "lastReachCheck" + (network.map { "/" + $0 } ?? ""))
    }

    var body: some View {
        let direct = Set(analysis.list.filter { s in s.lastDirect.map { Date.now.timeIntervalSince($0) <= ReachCheck.recent } ?? false }.map(\.key))
        // a repeater that answered the check is heard directly too
        let recent = result.map { $0.heardDirectly(recent: direct) } ?? direct.count
        Section {
            status(recent: recent)
            // your repeater gone quiet: a reach problem, shown here even when it's dropped out of the lists
            if let y = analysis.yours, let q = analysis.quiet(y.key) { QuietWarning(quiet: q, name: analysis.summary(y.key).name) }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let r = result, step == nil { rows(r) }
            actions
        } header: {
            if let name = model.networkName { Text(name) }
        }
    }

    // MARK: the status row

    private func status(recent: Int) -> some View {
        let (title, lines) = statusText(recent: recent)
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if step != nil {
                    ProgressView()
                } else if let r = result {
                    ReachLevelIcon(level: r.level)
                } else {
                    Image(systemName: recent == 0 ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(recent == 0 ? Color.orange : .secondary)
                }
            }
            .font(.title2)
            .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                ForEach(lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func statusText(recent: Int) -> (String, [String]) {
        let hearing = recent == 0 ? String(localized: "No repeater heard directly lately")
            : recent == 1 ? String(localized: "Hearing 1 repeater directly") : String(localized: "Hearing \(recent) repeaters directly")
        if let step { return (String(localized: "Checking reach…"), [step]) }
        if let r = result {
            let line = String(localized: "Hearing \(recent) directly · checked \(r.at.formatted(date: .omitted, time: .shortened))")
            return (r.summary.title, [r.summary.detail, line].compactMap { $0 })
        }
        let newest = analysis.list.compactMap(\.lastDirect).max()
        let heard = newest.map { d in
            let now = Date.now
            return HeardBadge.isNow(d, now: now) ? String(localized: "Last heard just now") : String(localized: "Last heard \(HeardBadge.short(d, now: now)) ago")
        } ?? String(localized: "Nothing heard straight from a repeater yet")
        return (hearing, [heard + " · " + (model.isConnected ? String(localized: "reach not checked") : String(localized: "connect to check reach"))])
    }

    // MARK: a row per repeater

    @ViewBuilder private func rows(_ r: ReachCheck) -> some View {
        let quiet = r.rows.filter { !$0.answered }
        let shown = showAllQuiet || quiet.count <= Self.quietShown ? quiet : Array(quiet.prefix(Self.quietShown))
        ForEach(r.rows.filter(\.answered)) { row($0) }
        ForEach(shown) { row($0) }
        if shown.count < quiet.count {
            Button("\(quiet.count - shown.count) more didn't answer") { withAnimation { showAllQuiet = true } }
                .font(.subheadline)
        }
    }

    /// A row links to the repeater's page; a new one (only the start of its key known) to what's known of
    /// it, until its advert is heard and it gets a name and page of its own.
    @ViewBuilder private func row(_ answer: ReachCheck.Row) -> some View {
        let row = resolved(answer)
        let key = row.key
        let view = ReachRow(row: row, isYours: key != nil && key == analysis.yours?.key,
                            busy: key.map { pinging.contains($0) } ?? false,
                            canPing: key.map { !pinging.contains($0) && !resting.contains($0) } ?? false && model.isConnected && step == nil,
                            ping: { Task { await ping(row) } })
        if let key {
            NavigationLink(value: key) { view }
        } else {
            NavigationLink(value: NewRepeaterAnswer(row: row, at: result?.at ?? .now)) { view }
        }
    }

    /// A new answerer whose advert has been heard since the check: named and linked like the rest.
    private func resolved(_ row: ReachCheck.Row) -> ReachCheck.Row {
        guard row.isNew else { return row }
        if let h = model.heard.first(where: { $0.key.hasPrefix(row.id) }) { return row.known(as: h.key, name: h.name) }
        if let c = model.contacts.values.first(where: { $0.key.hex.hasPrefix(row.id) }) { return row.known(as: c.key.hex, name: c.name) }
        return row
    }

    // MARK: the button

    private var actions: some View {
        let last = lastCheck > 0 ? Date(timeIntervalSince1970: lastCheck) : nil
        return HStack(spacing: 8) {
            // counting down only while there's a wait (a redraw a second otherwise for nothing)
            if step == nil, ReachCheck.wait(after: last) > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { t in checkButton(wait: ReachCheck.wait(after: last, now: t.date)) }
            } else {
                checkButton(wait: 0)
            }
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("How the reach check works")
        }
        .sheet(isPresented: $showInfo) { ReachInfoSheet(spreadingFactor: model.knownSpreadingFactor) }
        .task(id: model.isConnected) {
            guard model.isConnected, model.demoShow == "reach" else { return }
            try? await Task.sleep(for: .seconds(1))
            // (the card is made again once the network is known: only the one still showing checks)
            guard !Task.isCancelled, model.demoShow == "reach" else { return }
            model.demoShow = nil
            await check()
        }
    }

    private func checkButton(wait: TimeInterval) -> some View {
        Button { Task { await check() } } label: {
            Label(wait > 0 ? "Check again in \(Int(wait.rounded(.up))) s" : "Check reach", systemImage: "dot.radiowaves.left.and.right")
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(step != nil || wait > 0 || !model.isConnected)
    }

    // MARK: doing it

    private func check() async {
        problem = nil; result = nil; showAllQuiet = false
        step = String(localized: "Asking the repeaters in range…")
        defer { step = nil }
        lastCheck = Date.now.timeIntervalSince1970
        let candidates = analysis.list.compactMap { s in s.lastDirect.map { ReachCheck.Candidate(key: s.key, name: s.name, lastDirect: $0) } }
        var answers: [DiscoveryAnswer] = []
        do {
            answers = try await model.engine.checkReach()
        } catch {
            problem = String(localized: "The broadcast didn't go out (\(String(describing: error))). Pinging instead.")
        }
        // the ones you hear directly that stayed quiet: a ping each (every repeater answers those). A ping
        // that gets nothing back is kept as tried (nil), not dropped.
        var pings: [String: (up: Double, down: Double)?] = [:]
        let targets = ReachCheck.pingTargets(answers: answers, candidates: candidates)
        for (i, c) in targets.enumerated() {
            guard let pk = PublicKey(hex: c.key) else { continue }
            step = String(localized: "Pinging \(c.name)… \(i + 1) of \(targets.count)")
            do { pings.updateValue(try await model.engine.ping(pk), forKey: c.key) } catch { pings.updateValue(nil, forKey: c.key) }
        }
        let dir = model.directory
        let names = Dictionary(dir.nodes.map { ($0.key, $0.value.name) }, uniquingKeysWith: { a, _ in a })
        result = ReachCheck(answers: answers, candidates: candidates, nodes: names, lastHeard: analysis.list.map(\.lastSeen).max(),
                            spreadingFactor: model.knownSpreadingFactor ?? 8, pings: pings)
    }

    /// A ping by hand from a row: its answer goes into the result (the row moves up among the answers).
    private func ping(_ row: ReachCheck.Row) async {
        guard let key = row.key, let pk = PublicKey(hex: key) else { return }
        pinging.insert(key)
        var answer: (up: Double, down: Double)?
        do { answer = try await model.engine.ping(pk) } catch { answer = nil }
        pinging.remove(key)
        result = result?.adding(ping: answer, for: key, spreadingFactor: model.knownSpreadingFactor)
        resting.insert(key)
        try? await Task.sleep(for: .seconds(10))
        resting.remove(key)
    }
}

/// One repeater in a reach check: its name, how it answered (both ways) or didn't, and Ping for one that
/// didn't. Two lines, the verdict at the end of the first (under the name at the largest text sizes).
struct ReachRow: View {
    let row: ReachCheck.Row
    let isYours: Bool
    let busy: Bool
    let canPing: Bool
    let ping: () -> Void
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if isYours { YoursTag() } else if row.isNew { YoursTag(text: "New") }
                }
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            if !size.isAccessibilitySize { Spacer(minLength: 8) }
            trailing
        }
        .swipeActions {
            if !row.answered, row.key != nil, canPing {
                Button { ping() } label: { Label("Ping", systemImage: "dot.radiowaves.forward") }.tint(.accentColor)
            }
        }
        .contextMenu {
            if !row.answered, row.key != nil {
                Button { ping() } label: { Label("Ping", systemImage: "dot.radiowaves.forward") }.disabled(!canPing)
            }
        }
        .accessibilityActions {
            if !row.answered, canPing { Button("Ping") { ping() } }
        }
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small).frame(minWidth: 44, minHeight: 32)
        } else if let v = row.verdict {
            VerdictLabel(verdict: v).font(.subheadline.weight(.medium))
        } else if row.byPing {
            Label("No answer", systemImage: "minus.circle").font(.subheadline).foregroundStyle(.secondary)
        } else if row.key != nil {
            Button(action: ping) { Image(systemName: "dot.radiowaves.forward") }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(!canPing)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
                .accessibilityLabel("Ping \(row.name)")
        }
    }

    /// "↑ +2.8 dB · ↓ +3.8 dB", "heard 7 min ago · pinged, no answer", "heard 10 min ago · not pinged"
    private var detail: String {
        if row.answered { return "↑ \(ReachText.db(row.up)) · ↓ \(ReachText.db(row.down))" + (row.byPing ? " · " + String(localized: "ping") : "") }
        return [heard, row.byPing ? String(localized: "pinged, no answer") : String(localized: "not pinged")].compactMap { $0 }.joined(separator: " · ")
    }

    private var heard: String? {
        row.lastDirect.map { d in
            let now = Date.now
            return HeardBadge.isNow(d, now: now) ? String(localized: "heard just now") : String(localized: "heard \(HeardBadge.short(d, now: now)) ago")
        }
    }

    /// The row read out: its parts, each translated on its own, one after another with commas.
    private var spoken: String {
        if let v = row.verdict {
            let verdict = switch v {
            case .good: String(localized: "good")
            case .marginal: String(localized: "marginal")
            case .weak: String(localized: "weak")
            }
            return [row.name, isYours ? String(localized: "your repeater") : nil, verdict,
                    String(localized: "hears you \(ReachText.db(row.up))"), String(localized: "you hear it \(ReachText.db(row.down))"),
                    row.byPing ? String(localized: "by ping") : nil].compactMap { $0 }.joined(separator: ", ")
        }
        return [row.name, row.byPing ? String(localized: "no answer to a ping") : String(localized: "not pinged"), heard].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The check's overall level as a symbol in its colour: green only when the best answer is good.
struct ReachLevelIcon: View {
    let level: ReachCheck.Level

    var body: some View {
        switch level {
        case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .marginal: Image(systemName: "minus.circle.fill").foregroundStyle(.yellow)
        case .weak: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .hearOnly: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .deaf: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// What the reach check does and how to read it: behind the card's info button.
struct ReachInfoSheet: View {
    let spreadingFactor: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Check reach asks the repeaters in direct range how well they hear you (the request isn't passed on: a moment of airtime), then pings the ones you hear directly that didn't answer, since older repeater firmware only answers pings. You can wait a minute between checks.")
                }
                Section("Reading a row") {
                    LabeledContent("↑ +2.8 dB", value: String(localized: "how well it heard you"))
                    LabeledContent("↓ +3.8 dB", value: String(localized: "how well you heard it"))
                    LabeledContent("ping", value: String(localized: "it answered a one-hop ping"))
                    LabeledContent("Ping button", value: String(localized: "try one that didn't answer"))
                }
                Section {
                    LabeledContent { Text("10 dB or more above the limit") } label: { VerdictLabel(verdict: .good) }
                    LabeledContent { Text("5 to 10 dB above") } label: { VerdictLabel(verdict: .marginal) }
                    LabeledContent { Text("under 5 dB above") } label: { VerdictLabel(verdict: .weak) }
                } header: {
                    Text("Verdicts")
                } footer: {
                    if let sf = spreadingFactor {
                        Text("Judged by the weaker direction, against the weakest signal LoRa still decodes: \(SignalChartModel.db(ReachCheck.floor(spreadingFactor: sf))) dB at SF\(sf). Fading and other traffic eat into the margin, so a link wants about 10 dB.")
                    } else {
                        Text("Judged by the weaker direction, against the weakest signal LoRa still decodes. Fading and other traffic eat into the margin, so a link wants about 10 dB.")
                    }
                }
            }
            .navigationTitle("Check reach")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

enum ReachText {
    static func db(_ v: Double?) -> String { v.map { String(format: "%+.1f dB", $0) } ?? "—" }
}

/// Good / Marginal / Weak, in words with a symbol: the colour on the symbol only, so the word stays
/// readable (yellow text fails contrast in light mode).
struct VerdictLabel: View {
    let verdict: ReachCheck.Verdict

    var body: some View {
        Label {
            switch verdict {
            case .good: Text("Good")
            case .marginal: Text("Marginal")
            case .weak: Text("Weak")
            }
        } icon: {
            switch verdict {
            case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .marginal: Image(systemName: "minus.circle.fill").foregroundStyle(.yellow)
            case .weak: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// A one-hop trace to one repeater: how well it hears you, and you it.
struct PingButton: View {
    @Environment(AppModel.self) private var model
    let key: PublicKey
    @State private var busy = false
    @State private var answer: (up: Double, down: Double)?
    @State private var failed = false
    /// a short rest between pings (each is airtime on the shared channel)
    @State private var resting = false

    var body: some View {
        HStack {
            Button { Task { await ping() } } label: {
                if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pinging…") } } else { Label("Ping", systemImage: "dot.radiowaves.forward") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy || resting || !model.isConnected)
            if let a = answer {
                let v = ReachCheck.verdict(up: a.up, down: a.down, spreadingFactor: model.knownSpreadingFactor ?? 8)
                Text("hears you \(ReachText.db(a.up)) · you hear it \(ReachText.db(a.down))").font(.caption.monospacedDigit())
                VerdictLabel(verdict: v).font(.caption).labelStyle(.iconOnly)
            } else if failed {
                Text("No answer").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func ping() async {
        busy = true; failed = false
        do { answer = try await model.engine.ping(key) } catch { answer = nil; failed = true }
        busy = false
        // ready again in 10 s (a state change, so the button redraws itself enabled)
        resting = true
        try? await Task.sleep(for: .seconds(10))
        resting = false
    }
}

/// Ping on a repeater's page.
struct PingSection: View {
    let key: String
    let lastDirect: Date?

    var body: some View {
        if let pk = PublicKey(hex: key) {
            Section {
                PingButton(key: pk)
            } footer: {
                Text(lastDirect == nil
                     ? "You haven't heard this repeater directly, so a ping (one hop) is unlikely to reach it."
                     : "A one-hop trace: it goes to this repeater and back, and says how well each end heard the other.")
            }
        }
    }
}

/// A repeater to open from a path, wherever the path is shown (message details, packets, routes).
struct RepeaterLink: Hashable { let key: String }

extension View {
    /// Lets `NavigationLink(value: RepeaterLink(...))` inside this view open the repeater's page.
    func repeaterLinks() -> some View {
        navigationDestination(for: RepeaterLink.self) { RepeaterPage(key: $0.key) }
    }
}

/// A repeater's page on its own, from a link or the map: the last 7 days (worked out once and shared, so
/// usually at once). `tab` picks the part it opens on (4: Admin).
struct RepeaterPage: View {
    @Environment(AppModel.self) private var model
    let key: String
    var tab = 0
    @State private var analysis: RepeaterAnalysis?

    var body: some View {
        Group {
            if let analysis { RepeaterDetailView(analysis: analysis, key: key, tab: tab) } else { ProgressView() }
        }
        .task { analysis = await model.repeaterAnalysis(days: 7) }
    }
}

/// Which repeaters the list shows.
enum RepeaterFilter: String, CaseIterable {
    case all, direct, further, contacts, located

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .direct: String(localized: "Heard directly")
        case .further: String(localized: "Further along the mesh")
        case .contacts: String(localized: "Contacts")
        case .located: String(localized: "On the map")
        }
    }

    func keeps(_ s: RepeaterAnalysis.Summary) -> Bool {
        switch self {
        case .all: true
        case .direct: s.direct
        case .further: !s.direct
        case .contacts: s.isContact
        case .located: s.position != nil
        }
    }
}

/// The order within each part of the list.
enum RepeaterSort: String, CaseIterable {
    case relayed, signal, distance, heard, name

    var label: String {
        switch self {
        case .relayed: String(localized: "Most passed on")
        case .signal: String(localized: "Signal")
        case .distance: String(localized: "Distance")
        case .heard: String(localized: "Last heard")
        case .name: String(localized: "Name")
        }
    }

    func inOrder(_ a: RepeaterAnalysis.Summary, _ b: RepeaterAnalysis.Summary) -> Bool {
        switch self {
        case .relayed: (a.relayed, b.name) > (b.relayed, a.name)
        case .signal: (a.snrMedian ?? -.infinity, b.name) > (b.snrMedian ?? -.infinity, a.name)
        case .distance: (a.km ?? .infinity, a.name) < (b.km ?? .infinity, b.name)
        case .heard: (a.lastSeen, b.name) > (b.lastSeen, a.name)
        case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// "Your repeater has gone quiet", with what's reaching you instead.
struct QuietWarning: View {
    @Environment(AppModel.self) private var model
    let quiet: RepeaterAnalysis.Quiet
    let name: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) has gone quiet").font(.subheadline.weight(.semibold))
                Text("Nothing heard straight from it since \(quiet.since.formatted(date: .omitted, time: .shortened)), while \(quiet.missed) packets arrived (about \(quiet.expected) would usually be its own). Your messages may not get through.")
                    .font(.caption)
                if let n = quiet.next {
                    let signal = String(format: "%.1f dB", n.snr)
                    if let p = n.position, let h = model.home {
                        Text("Best reaching you now: \(n.name), \(signal) · \(Int(Geo.km(h, p))) km \(Geo.bearing(h, p))").font(.caption)
                    } else {
                        Text("Best reaching you now: \(n.name), \(signal)").font(.caption)
                    }
                }
            }
        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
    }
}

/// One repeater: activity, signal at your radio, who enters the mesh through it, its links, and its
/// live status and neighbours on request.
struct RepeaterDetailView: View {
    @Environment(AppModel.self) private var model
    let analysis: RepeaterAnalysis
    let key: String
    @State private var tab: Int
    @State private var answer: LiveAnswer?
    @State private var password = ""
    @State private var asking = false

    init(analysis: RepeaterAnalysis, key: String, tab: Int = 0) {
        self.analysis = analysis
        self.key = key
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let s = analysis.summary(key), st = analysis.stats[key] ?? RepeaterAnalysis.Stats()
        Form {
            Picker("Show", selection: $tab) { Text("Overview").tag(0); Text("People").tag(1); Text("Links").tag(2); Text("Live").tag(3); Text("Admin").tag(4) }
                .pickerStyle(.segmented)
            switch tab {
            case 0: overview(s, st)
            case 1: people(st)
            case 2: links(st)
            case 3: live
            default: AdminSections(key: key)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(s.name)
        .task { answer = try? model.store.liveAnswer(key) }
    }

    @ViewBuilder private func overview(_ s: RepeaterAnalysis.Summary, _ st: RepeaterAnalysis.Stats) -> some View {
        PingSection(key: key, lastDirect: s.lastDirect)
        Section {
            LabeledContent("Passed on", value: "\(s.relayed)")
            LabeledContent("Entered the mesh here", value: "\(s.firstHop)")
            LabeledContent("Heard straight from it", value: s.direct ? String(localized: "\(s.lastHop) packets") : String(localized: "no"))
            if let snr = s.snrMedian { LabeledContent("Median signal", value: String(format: "%.2f dB", snr)) }
            if let km = s.km { LabeledContent("Distance", value: String(format: "%.1f km", km)) }
            if st.heardYou > 0 { LabeledContent("Your messages that entered here", value: "\(st.heardYou)") }
        }
        ActivitySection(activity: s.activity)
        if !st.signal.isEmpty || st.heardYou > 0 {
            SignalSection(chart: SignalChartModel(points: st.signal, spreadingFactor: model.knownSpreadingFactor), heard: st.signal.count,
                          days: analysis.days, heardYou: st.heardYou,
                          heardYouLast: st.heardYouLast == .distantPast ? nil : st.heardYouLast, direct: s.direct)
        }
    }

    private func people(_ st: RepeaterAnalysis.Stats) -> some View {
        Section {
            let users = (Array(st.people.values) + Array(st.nodes.values)).sorted { $0.lastSeen > $1.lastSeen }
            if users.isEmpty { Text("Nobody seen entering the mesh here yet.").foregroundStyle(.secondary) }
            ForEach(users) { u in
                LabeledContent {
                    Text(u.lastSeen.formatted(.relative(presentation: .named))).font(.caption)
                } label: {
                    Text(u.name ?? "?") + Text(u.uncertain ? " (?)" : "").foregroundStyle(.secondary)
                    Text("\(u.count)× · \(u.via.sorted().joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: { Text("Who enters the mesh through it: the first repeater in their packets' paths.") }
    }

    private func links(_ st: RepeaterAnalysis.Stats) -> some View {
        Section {
            ForEach(st.links.values.sorted { $0.to + $0.from > $1.to + $1.from }) { l in
                LabeledContent(analysis.directory.nodes[l.key]?.name ?? String(l.key.prefix(8)), value: "→ \(l.to)  ← \(l.from)")
            }
        } footer: { Text("Repeaters it exchanges packets with (next to it in paths).") }
    }

    @ViewBuilder private var live: some View {
        Section {
            SecureField("Password (empty: guest)", text: $password).autocorrectionDisabled()
            Button { Task { await ask() } } label: {
                if asking { HStack { ProgressView(); Text("Waiting… 5–30 s") } } else { Text(answer == nil ? "Ask for status and neighbours" : "Ask again") }
            }
            .disabled(asking || !model.isConnected || PublicKey(hex: key).flatMap { model.contacts[$0] } == nil)
        } footer: {
            Text("Logs in, asks for its status and the repeaters it hears directly, then logs out: three short transmissions. If the saved route to it doesn't answer, it asks once more by flood.")
        }
        if let a = answer {
            if let e = a.error { Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            if let s = a.status.flatMap(NodeStatus.init) { StatusSection(status: s, asOf: a.date, room: false) }
            else if a.ok {
                Section("Status") {
                    Text("It didn't send its status (uptime, power, traffic) back in time: the request or its answer was lost on the way. Ask again.")
                        .foregroundStyle(.secondary)
                }
            }
            if let n = a.neighbours {
                Section("Hears directly (\(a.neighboursTotal ?? n.count))") {
                    ForEach(n, id: \.prefix) { nb in
                        LabeledContent(analysis.directory.candidates(nb.prefix).first?.name ?? nb.prefix,
                                       value: String(format: "%.1f dB", nb.snr) + " · "
                                           + String(localized: "\(Duration.seconds(nb.secondsAgo).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))) ago"))
                    }
                }
            }
        }
    }

    private func ask() async {
        guard let k = PublicKey(hex: key) else { return }
        asking = true; defer { asking = false }
        let pwd = password; password = ""
        answer = try? await model.engine.query(k, password: pwd)
    }
}


/// A reach-check answer from a repeater whose advert hasn't been heard here.
struct NewRepeaterAnswer: Hashable {
    let row: ReachCheck.Row
    let at: Date
}

/// What's known of a repeater that answered the reach check before its advert was heard: the start of its
/// key and how well each of you heard the other. Its page proper comes with its advert.
struct NewRepeaterView: View {
    @Environment(AppModel.self) private var model
    let answer: NewRepeaterAnswer

    var body: some View {
        let r = answer.row
        Form {
            Section {
                if let v = r.verdict { LabeledContent("Reach") { VerdictLabel(verdict: v).fixedSize() } }
                LabeledContent("It hears you", value: ReachText.db(r.up))
                LabeledContent("You hear it", value: ReachText.db(r.down))
                LabeledContent("Checked", value: answer.at.formatted(date: .omitted, time: .shortened))
            } header: { Text("Its answer") }
            Section {
                LabeledContent("Key starts") { Text(r.id).font(.body.monospaced()).textSelection(.enabled) }
            } footer: {
                Text("It answered your reach check, which gives only the start of its key, but its advert hasn't been heard here yet, so its name, place and history aren't known. They fill in once it is: repeaters advertise every few hours. Till then it can't be pinged or added as a contact.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(r.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}


/// A small capsule after a repeater's name: "Yours" (it passes on your messages first), "New".
struct YoursTag: View {
    var text: LocalizedStringKey = "Yours"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}
