import MeshChatCore
import MeshCoreKit
import SwiftUI

/// A map region kept on the device, and how far its download has got.
public struct OfflinePack: Identifiable, Hashable, Sendable {
    public let region: OfflineRegion
    public var completed: Int
    public var expected: Int
    public var bytes: Int
    public var isComplete: Bool
    public var failure: String?
    public var id: String { region.name }

    public init(region: OfflineRegion, completed: Int, expected: Int, bytes: Int, isComplete: Bool, failure: String? = nil) {
        self.region = region; self.completed = completed; self.expected = expected; self.bytes = bytes
        self.isComplete = isComplete; self.failure = failure
    }

    public var fraction: Double { expected > 0 ? min(1, Double(completed) / Double(expected)) : 0 }
}

/// The map itself and its offline storage, supplied by the app (MapLibre with OpenFreeMap vector tiles),
/// so these screens stay free of a map engine and build anywhere.
@MainActor
public protocol MapProvider: AnyObject, Observable {
    /// The map with these points, grouped into clusters where they crowd together when `clustered`, a
    /// route line (in the order travelled) that it fits on screen when it changes, and a node's `links`
    /// as thinner lines. Centres on `focus` each time a new one comes, and eases to a node when it's
    /// selected. The map runs under the bars (it keeps its own buttons and logo clear of them);
    /// `bottomInset` is covered by the card, so centring happens above it.
    func map(points: [MapContent.Point], route: [Position], links: [[Position]], clustered: Bool, focus: MapFocus?,
             selection: Binding<String?>, bottomInset: CGFloat) -> AnyView
    /// What the map shows now, to keep offline.
    var visibleArea: OfflineRegion? { get }
    var packs: [OfflinePack] { get }
    func download(_ region: OfflineRegion) async throws
    func remove(_ pack: OfflinePack) async throws
    /// Shown under the map list: the map data's licence.
    var attribution: String { get }
}

/// Where the map should centre: a place, and a serial, so asking for the same place again (Home, twice)
/// moves the map again.
public struct MapFocus: Equatable, Sendable {
    public let position: Position
    public let serial: Int
    /// how far in to zoom; nil: to street level, or stay closer if already there
    public let zoom: Double?

    public init(_ position: Position, serial: Int, zoom: Double? = nil) {
        self.position = position
        self.serial = serial
        self.zoom = zoom
    }
}

/// Every node with a known position, and home, clustered where they crowd together. Filter by kind; tap
/// one for a card with what's known about it and what you can do. Or a message's route: just the nodes
/// it passed, joined up.
struct MapTab: View {
    @Environment(AppModel.self) private var model
    let provider: (any MapProvider)?
    @State private var selection: String?
    @State private var kinds: Set<MapContent.Point.Kind> = [.person, .repeater, .room, .sensor, .home]
    @State private var contactsOnly = false
    @AppStorage("mapGrouping") private var grouping = true
    @State private var showOffline = false
    @State private var focus: MapFocus?
    @State private var focusSerial = 0
    /// the repeaters worked out from the packet log (shared with the Repeaters tab), for the card's numbers
    @State private var analysis: RepeaterAnalysis?
    @State private var showLinks = false
    @State private var cardHeight: CGFloat = 0

    /// what was heard on the radio's network (contacts heard only on others aren't drawn)
    private var content: MapContent { MapContent(contacts: model.contactsHere, heard: model.heard, home: model.home) }

    var body: some View {
        NavigationStack {
            Group {
                if let provider {
                    let content = content
                    let route = model.mapRoute
                    let points = route?.points ?? content.points.filter { kinds.contains($0.kind) && (!contactsOnly || $0.isContact || $0.kind == .home) }
                    let selected = selection.flatMap { id in content.points.first { $0.id == id } ?? route?.points.first { $0.id == id } }
                    let links = showLinks ? selected.flatMap { s in analysis.map { MapLinks.lines(from: s.id, analysis: $0) } } ?? [] : []
                    // the whole screen, under the navigation and tab bars; the cards stay clear of them
                    // (the bars above and below are about as tall, so the screen's centre is the middle of
                    // what's in view; only the card needs room)
                    ZStack {
                        provider.map(points: points, route: route?.positions ?? [], links: links, clustered: route == nil && grouping, focus: focus,
                                     selection: $selection, bottomInset: selected == nil ? 0 : cardHeight + 8)
                            .ignoresSafeArea()
                    }
                        .overlay(alignment: .top) { if let route { routeCard(route) } }
                        .overlay(alignment: .bottom) {
                            if let p = selected {
                                MapNodeCard(point: p, analysis: analysis, showLinks: $showLinks,
                                            close: { selection = nil }, offlineMaps: { showOffline = true })
                                    .id(p.id)
                                    .background {
                                        GeometryReader { g in
                                            Color.clear
                                                .onAppear { cardHeight = g.size.height }
                                                .onChange(of: g.size.height) { _, h in cardHeight = h }
                                        }
                                    }
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: selection)
                } else {
                    ContentUnavailableView("No map on this device", systemImage: "map")
                }
            }
            .navigationTitle("Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .modifier(NoTitleOverMap())
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Toggle("People", isOn: binding(.person))
                        Toggle("Repeaters", isOn: binding(.repeater))
                        Toggle("Rooms", isOn: binding(.room))
                        Toggle("Sensors", isOn: binding(.sensor))
                        Divider()
                        Toggle("Contacts only", isOn: $contactsOnly)
                        Divider()
                        Toggle("Group nearby markers", isOn: $grouping)
                    } label: { Label("Show", systemImage: "line.3.horizontal.decrease.circle") }
                    .disabled(model.mapRoute != nil)
                    if let home = model.home {
                        Button { center(on: home) } label: { Label("Home", systemImage: "house") }
                    }
                    Button { showOffline = true } label: { Label("Offline maps", systemImage: "arrow.down.circle") }
                        .disabled(provider == nil)
                }
            }
            .repeaterLinks()
            .sheet(isPresented: $showOffline) { if let provider { OfflineMapsView(provider: provider) } }
            .onAppear {
                model.reloadHeard()
                if model.mapFocus != nil { focusRequested() }
                else if focus == nil, model.mapRoute == nil, model.isDemo { center(on: DemoMesh.overview, zoom: DemoMesh.overviewZoom) }
                else if focus == nil, model.mapRoute == nil, let home = model.home { center(on: home) }   // a route fits itself
            }
            .onChange(of: model.mapFocus) { focusRequested() }
            .onChange(of: selection) { showLinks = false }
            // the card's numbers, worked out once and shared (a tap never waits for them)
            .task(id: model.packetVersion / 25) { analysis = await model.repeaterAnalysis(days: 7) }
        }
    }

    private func center(on p: Position, zoom: Double? = nil) {
        focusSerial += 1
        focus = MapFocus(p, serial: focusSerial, zoom: zoom)
    }

    /// "Show on map" from elsewhere: select the node and centre on it.
    private func focusRequested() {
        guard let f = model.mapFocus else { return }
        selection = f
        if let p = content.points.first(where: { $0.id == f }) { center(on: p.position) }
        model.mapFocus = nil
    }

    private func binding(_ k: MapContent.Point.Kind) -> Binding<Bool> {
        Binding(get: { kinds.contains(k) }, set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } })
    }

    /// What the line shows, over the map: the route's ends and repeaters, and what couldn't be placed.
    private func routeCard(_ r: MapRoute) -> some View {
        let km = zip(r.positions, r.positions.dropFirst()).reduce(0) { $0 + Geo.km($1.0, $1.1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.tint)
                Text(r.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { model.mapRoute = nil; selection = nil }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text(r.summary).font(.caption).lineLimit(2)
            Text([r.hops == 0 ? String(localized: "direct") : r.hops == 1 ? String(localized: "1 hop") : String(localized: "\(r.hops) hops"),
                  String(localized: "\(String(format: "%.0f", km)) km as drawn"),
                  r.hidden > 0 ? (r.hidden == 1 ? String(localized: "1 repeater with no known position left out")
                                                : String(localized: "\(r.hidden) repeaters with no known position left out")) : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The map is the whole screen: no title over it, just its buttons (iOS 18 and later; the title stays
/// before that, where it can't be taken out of the bar).
private struct NoTitleOverMap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

extension MapContent {
    /// The SF Symbol for a kind of point.
    public static func symbol(_ k: Point.Kind) -> String {
        switch k {
        case .person: "person.fill"
        case .repeater: "antenna.radiowaves.left.and.right"
        case .room: "person.3.fill"
        case .sensor: "sensor.fill"
        case .home: "house.fill"
        }
    }
}

/// Map regions kept on the device, so the map works with no internet: around home, or the area on screen.
struct OfflineMapsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: any MapProvider
    @State private var radius = 50.0
    @State private var maxZoom = 13
    @State private var name = ""
    @State private var problem: String?
    @State private var confirmRemove: OfflinePack?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if provider.packs.isEmpty { Text("None yet. The map works offline only in regions kept here.").foregroundStyle(.secondary) }
                    ForEach(provider.packs) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.region.name)
                                Spacer()
                                Text(p.bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if let f = p.failure { Text(f).font(.caption).foregroundStyle(.orange) }
                            else if p.isComplete { Text("Ready offline · zoom up to \(p.region.maxZoom)").font(.caption).foregroundStyle(.secondary) }
                            else { ProgressView(value: p.fraction) { Text("Downloading \(p.completed) of \(p.expected)").font(.caption) } }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { confirmRemove = p } }
                        .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { confirmRemove = p } }
                    }
                } header: { Text("On this device") }

                Section {
                    Picker("Detail", selection: $maxZoom) {
                        Text("Towns (zoom 11)").tag(11); Text("Streets (zoom 13)").tag(13); Text("Every street (zoom 14)").tag(14)
                    }
                } footer: { Text("More detail is a bigger download. Zoomed in further, the map stretches the most detailed level it has.") }
                if let home = model.home {
                    Section {
                        Picker("Distance", selection: $radius) {
                            Text("25 km").tag(25.0); Text("50 km").tag(50.0); Text("100 km").tag(100.0); Text("150 km").tag(150.0)
                        }
                        download(OfflineRegion.around(home, radiusKm: radius, name: regionName(String(localized: "Around home")), maxZoom: maxZoom))
                    } header: { Text("Around home") }
                } else {
                    Section("Around home") {
                        NavigationLink("Set your home location first") { HomeLocationView() }
                    }
                }
                if let v = provider.visibleArea {
                    Section("The area on the map now") {
                        download(OfflineRegion(name: regionName(String(localized: "Map area")), south: v.south, west: v.west, north: v.north, east: v.east, maxZoom: maxZoom))
                    }
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                Section {} footer: { Text(provider.attribution) }
            }
            .formStyle(.grouped)
            .navigationTitle("Offline maps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // asked from the list, not from the row: a dialog whose row goes away with the deletion took the
            // whole sheet down with it
            .confirmationDialog("Delete \(confirmRemove?.region.name ?? String(localized: "this map"))?", isPresented: .present($confirmRemove),
                                titleVisibility: .visible, presenting: confirmRemove) { p in
                Button("Delete", role: .destructive) { remove(p) }
            } message: { _ in Text("The map there needs the internet again until you download it.") }
        }
    }

    private func remove(_ p: OfflinePack) {
        Task {
            do { try await provider.remove(p); problem = nil } catch { problem = String(localized: "Not deleted: \(String(describing: error))") }
        }
    }

    /// A name not already used.
    private func regionName(_ base: String) -> String {
        let used = Set(provider.packs.map(\.region.name))
        if !used.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !used.contains($0) }!
    }

    private func download(_ r: OfflineRegion) -> some View {
        Button {
            Task { do { try await provider.download(r); problem = nil } catch { problem = "\(error)" } }
        } label: {
            LabeledContent("Download", value: String(localized: "about \(r.estimatedBytes.formatted(.byteCount(style: .file)))"))
        }
        .disabled(r.tileCount > OfflineRegion.maxTiles)
        .accessibilityHint("\(r.tileCount) map tiles")
        .help(r.tileCount > OfflineRegion.maxTiles ? "Too big: choose less detail or a smaller area" : "\(r.tileCount) map tiles")
    }
}
