import MeshChatCore
import MeshCoreKit
import SwiftUI

/// The card for a node tapped on the map, floating over its bottom edge: what it is and where, the few
/// numbers that matter, and what you can do with it (all worked out in `NodeCard`). For a repeater:
/// ping it, open its page, draw its links. Swipe it down, tap the map or the close button to close it.
struct MapNodeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let point: MapContent.Point
    /// nil while it's still being worked out: the numbers show as placeholders
    let analysis: RepeaterAnalysis?
    @Binding var showLinks: Bool
    let close: () -> Void
    let offlineMaps: () -> Void

    @State private var pinging = false
    @State private var resting = false
    @State private var pingAnswer: (up: Double, down: Double)?
    @State private var pingFailed = false
    @State private var confirmRemove = false
    @State private var openAdmin = false
    @State private var asking = false
    @State private var problem: String?
    @State private var drag: CGFloat = 0

    private var key: PublicKey? { PublicKey(hex: point.id) }

    private var summary: RepeaterAnalysis.Summary? {
        guard let analysis, analysis.stats[point.id] != nil else { return nil }
        return analysis.summary(point.id)
    }

    var body: some View {
        let now = Date.now
        let card = NodeCard(point: point, summary: summary, heard: model.heard.first { $0.key == point.id }, home: model.distanceOrigin,
                            isYours: analysis?.yours?.key == point.id, quietSince: analysis?.quiet(point.id, now: now)?.since,
                            directRepeaters: point.kind == .home ? analysis.map { a in
                                a.list.filter { $0.lastDirect.map { now.timeIntervalSince($0) <= 3600 } ?? false }.count
                            } : nil,
                            now: now, idBytes: (model.device?.pathHashMode ?? 0) + 1)
        let loading = analysis == nil && (point.kind == .repeater || point.kind == .room || point.kind == .home)
        VStack(alignment: .leading, spacing: 12) {
            header(card)
            if loading {
                stats([NodeCard.Stat(value: "2 min · +6.5 dB", label: String(localized: "heard directly")),
                       NodeCard.Stat(value: "000", label: String(localized: "passed on, 3 h")),
                       NodeCard.Stat(value: "0 · 0", label: String(localized: "people · links"))])
                    .redacted(reason: .placeholder)
            } else if !card.stats.isEmpty {
                stats(card.stats)
            }
            actions(card)
            if let a = pingAnswer {
                let v = ReachCheck.verdict(up: a.up, down: a.down, spreadingFactor: model.knownSpreadingFactor ?? 8)
                HStack(spacing: 6) {
                    VerdictLabel(verdict: v)
                    Text("hears you \(ReachText.db(a.up)) · you hear it \(ReachText.db(a.down))").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if pingFailed {
                Text("No answer to the ping.").font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .modifier(CardBackground())
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 60 { close() } else { withAnimation(.snappy) { drag = 0 } }
                }
        )
        .navigationDestination(isPresented: $openAdmin) { RepeaterPage(key: point.id, tab: 4) }
        .sheet(isPresented: $asking) { if let key { NodeQueryView(key: key) } }
        .confirmationDialog("Remove \(point.name) from contacts?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("It's removed from your radio's contacts. Messages already on this iPhone stay.")
        }
    }

    // MARK: parts

    private func header(_ card: NodeCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: MapContent.symbol(point.kind))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(MapContent.color(point.kind), in: .circle)
                    .accessibilityHidden(true)
                Text(point.name).font(.headline).lineLimit(1)
                if let id = card.id {
                    Text(id)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                        .accessibilityLabel("ID \(id.map(String.init).joined(separator: " "))")
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            HStack(spacing: 6) {
                if let q = card.quiet {
                    Label(q, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(card.subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(card.tags, id: \.self) { t in
                    Text(t)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.caption)
        }
    }

    /// Up to three numbers in equal columns, the value over what it is.
    private func stats(_ list: [NodeCard.Stat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    Text(s.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func actions(_ card: NodeCard) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(card.primary.enumerated()), id: \.offset) { i, a in
                action(a)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .modifier(CardButton(prominent: i == 0 || (a == .links && showLinks)))
            }
            if !card.menu.isEmpty {
                Menu {
                    ForEach(card.menu, id: \.self) { menuItem($0) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder private func action(_ a: NodeCard.Action) -> some View {
        switch a {
        case .ping:
            Button { Task { await ping() } } label: {
                if pinging {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pinging") }.frame(maxWidth: .infinity)
                } else {
                    Label("Ping", systemImage: "dot.radiowaves.forward").frame(maxWidth: .infinity)
                }
            }
            .disabled(pinging || resting || !model.isConnected || key == nil)
        case .details:
            NavigationLink {
                if point.kind == .room, let key { RoomDetailsView(key: key) } else { RepeaterPage(key: point.id) }
            } label: {
                Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
            }
        case .links:
            Toggle(isOn: $showLinks) {
                Label("Links", systemImage: "point.3.connected.trianglepath.dotted").frame(maxWidth: .infinity)
            }
            .toggleStyle(.button)
            .disabled((summary?.links ?? 0) == 0)
        case .message, .openRoom:
            Button { if let key { model.open(.direct(key)) } } label: {
                Label(a == .message ? "Message" : "Open room", systemImage: a == .message ? "bubble.left.fill" : "person.3.fill")
                    .frame(maxWidth: .infinity)
            }
        case .route:
            if let key {
                NavigationLink { RouteDetailsView(key: key) } label: {
                    Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth: .infinity)
                }
            }
        case .query:
            Button { asking = true } label: {
                Label("Readings", systemImage: "gauge.with.dots.needle.33percent").frame(maxWidth: .infinity)
            }
            .disabled(key == nil)
        case .addContact:
            Button { Task { await add() } } label: {
                Label("Add contact", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
            }
            .disabled(!model.isConnected || key == nil)
        case .changeHome:
            NavigationLink { HomeLocationView() } label: {
                Label("Change", systemImage: "house").frame(maxWidth: .infinity)
            }
        case .offlineMaps:
            Button(action: offlineMaps) {
                Label("Offline maps", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func menuItem(_ a: NodeCard.Action) -> some View {
        switch a {
        case .addContact:
            Button { Task { await add() } } label: { Label("Add to contacts", systemImage: "person.badge.plus") }
                .disabled(!model.isConnected || key == nil)
        case .query:
            Button { asking = true } label: {
                Label(point.kind == .repeater ? "Status and readings…" : "Ask for readings…", systemImage: "gauge.with.dots.needle.33percent")
            }
        case .adminLogin:
            Button { openAdmin = true } label: { Label("Admin…", systemImage: "lock") }
        case .directions:
            Button(action: directions) { Label("Directions in Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }
        case .copyID:
            Button { copyToClipboard(point.id) } label: { Label("Copy public key", systemImage: "number") }
        case .copyPosition:
            Button { copyToClipboard(String(format: "%.5f, %.5f", point.position.latitude, point.position.longitude)) } label: {
                Label("Copy coordinates", systemImage: "doc.on.doc")
            }
        case .removeContact:
            Divider()
            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from contacts…", systemImage: "person.badge.minus") }
                .disabled(!model.isConnected)
        default:
            EmptyView()
        }
    }

    // MARK: doing it

    /// A one-hop trace to it and back: how well each end hears the other. Rests 10 s after (airtime).
    private func ping() async {
        guard let key else { return }
        pinging = true
        pingFailed = false
        do { pingAnswer = try await model.engine.ping(key) } catch { pingAnswer = nil; pingFailed = true }
        pinging = false
        resting = true
        try? await Task.sleep(for: .seconds(10))
        resting = false
    }

    private func add() async {
        guard let key else { return }
        let type: NodeType = switch point.kind {
        case .repeater: .repeater
        case .room: .room
        case .sensor: .sensor
        case .person, .home: .companion
        }
        do { _ = try await model.engine.addContact(key: key, name: point.name, type: type); problem = nil } catch { problem = "\(error)" }
    }

    private func remove() async {
        guard let key else { return }
        do { try await model.engine.removeContact(key); problem = nil } catch { problem = "\(error)" }
    }

    private func directions() {
        let p = point.position
        if let url = URL(string: String(format: "https://maps.apple.com/?daddr=%.6f,%.6f", p.latitude, p.longitude)) { openURL(url) }
    }
}

extension MapContent {
    /// A kind's colour, as its markers on the map.
    static func color(_ k: Point.Kind) -> Color {
        switch k {
        case .person: .blue
        case .repeater: .orange
        case .room: .purple
        case .sensor: .teal
        case .home: .green
        }
    }
}

/// The card's buttons: equal capsules, the first one filled.
private struct CardButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        }
    }
}

/// Glass on iOS 26 and later, as the floating tab bar; a material card before that.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 24)).shadow(color: .black.opacity(0.15), radius: 10, y: 2)
        }
        #else
        content.background(.regularMaterial, in: .rect(cornerRadius: 24))
        #endif
    }
}
