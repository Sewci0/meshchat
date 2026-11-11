import CoreLocation
import MapLibre
import MeshChatCore
import MeshChatUI
import MeshCoreKit
import SwiftUI
import UIKit

/// The map: MapLibre Native drawing OpenFreeMap's vector tiles (free, no key, OpenStreetMap data), with
/// regions downloaded for offline use. Without the internet the map shows what's been kept, and the
/// nodes on it still come from your radio.
@MainActor @Observable
final class MapLibreMaps: MapProvider {
    static let style = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    /// the same tiles, icons and fonts, drawn dark: in dark mode
    static let darkStyle = URL(string: "https://tiles.openfreemap.org/styles/dark")!
    static func style(dark: Bool) -> URL { dark ? darkStyle : style }
    /// the pack that keeps the dark style itself offline (its tiles are the regions' own)
    private static let darkStyleContext = Data(#"{"keeps":"dark style"}"#.utf8)

    var visibleArea: OfflineRegion?
    private(set) var packs: [OfflinePack] = []
    let attribution = String(localized: "Map data © OpenStreetMap contributors (openstreetmap.org/copyright). Tiles by OpenFreeMap, based on OpenMapTiles.")

    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var resumed: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    enum MapError: Error, CustomStringConvertible {
        case couldNotStart
        var description: String { String(localized: "The download couldn't start. Check the internet connection and try again.") }
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPacks() }
        })
        observers.append(center.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] n in
            let context = (n.object as? MLNOfflinePack)?.context
            let why = (n.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError)?.localizedDescription ?? String(localized: "The download stopped.")
            MainActor.assumeIsolated { self?.failed(context: context, why: why) }
        })
        // the storage loads its packs in the background at launch
        Task { [weak self] in
            for _ in 0..<40 {
                if MLNOfflineStorage.shared.packs != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.startPacks()
        }
    }

    // MARK: the map

    func map(points: [MapContent.Point], route: [Position], links: [[Position]], clustered: Bool, focus: MapFocus?,
             selection: Binding<String?>, bottomInset: CGFloat) -> AnyView {
        AnyView(MapLibreView(points: points, route: route, links: links, clustered: clustered, focus: focus, selection: selection,
                             bottomInset: bottomInset) { [weak self] area in
            self?.visibleArea = area
        })
    }

    // MARK: offline regions

    func download(_ r: OfflineRegion) async throws {
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: r.south, longitude: r.west),
                                         ne: CLLocationCoordinate2D(latitude: r.north, longitude: r.east))
        let region = MLNTilePyramidOfflineRegion(styleURL: Self.style, bounds: bounds,
                                                 fromZoomLevel: Double(r.minZoom), toZoomLevel: Double(r.maxZoom))
        let context = try JSONEncoder().encode(r)
        failures[r.name] = nil
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            MLNOfflineStorage.shared.addPack(for: region, withContext: context) { pack, error in
                if let pack {
                    pack.resume()
                    c.resume()
                } else {
                    c.resume(throwing: error ?? MapError.couldNotStart)
                }
            }
        }
        resumed.insert(r.name)
        keepDarkStyle()
        reloadPacks()
    }

    func remove(_ p: OfflinePack) async throws {
        guard let pack = (MLNOfflineStorage.shared.packs ?? []).first(where: { Self.region(of: $0)?.name == p.region.name }) else { return }
        pack.suspend()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            MLNOfflineStorage.shared.removePack(pack) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        failures[p.region.name] = nil
        keepDarkStyle()
        reloadPacks()
    }

    /// Dark mode offline: both styles draw the same tiles, icons and fonts, so the regions' downloads
    /// serve both, and only the dark style's own description needs keeping. One tiny pack (zoom 0) holds
    /// it while there are regions; it goes with the last one.
    private func keepDarkStyle() {
        let all = MLNOfflineStorage.shared.packs ?? []
        let regions = all.filter { Self.region(of: $0) != nil }
        let dark = all.first { $0.context == Self.darkStyleContext }
        if regions.isEmpty {
            if let dark { MLNOfflineStorage.shared.removePack(dark, withCompletionHandler: nil) }
            return
        }
        if let dark {
            if dark.state == .inactive || dark.state == .unknown { dark.resume() }
            return
        }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: 49, longitude: 14), ne: CLLocationCoordinate2D(latitude: 55, longitude: 24))
        let region = MLNTilePyramidOfflineRegion(styleURL: Self.darkStyle, bounds: bounds, fromZoomLevel: 0, toZoomLevel: 0)
        MLNOfflineStorage.shared.addPack(for: region, withContext: Self.darkStyleContext) { pack, _ in pack?.resume() }
    }

    private static func region(of pack: MLNOfflinePack) -> OfflineRegion? {
        try? JSONDecoder().decode(OfflineRegion.self, from: pack.context)
    }

    /// At launch: ask each pack how far it got, and carry on with unfinished downloads.
    private func startPacks() {
        for pack in MLNOfflineStorage.shared.packs ?? [] where pack.state == .unknown { pack.requestProgress() }
        keepDarkStyle()   // regions kept before dark mode
        reloadPacks()
    }

    private func failed(context: Data?, why: String) {
        if let context, let r = try? JSONDecoder().decode(OfflineRegion.self, from: context) { failures[r.name] = why }
        reloadPacks()
    }

    private func reloadPacks() {
        let all = MLNOfflineStorage.shared.packs ?? []
        for pack in all where pack.state == .inactive {
            // unfinished from an earlier launch: resume it once
            if let r = Self.region(of: pack), !resumed.contains(r.name), failures[r.name] == nil,
               pack.progress.countOfResourcesCompleted < pack.progress.countOfResourcesExpected {
                resumed.insert(r.name)
                pack.resume()
            }
        }
        packs = all.compactMap { pack in
            guard let r = Self.region(of: pack) else { return nil }
            let pr = pack.progress
            return OfflinePack(region: r, completed: Int(pr.countOfResourcesCompleted), expected: Int(pr.countOfResourcesExpected),
                               bytes: Int(pr.countOfBytesCompleted), isComplete: pack.state == .complete, failure: failures[r.name])
        }
        .sorted { $0.region.name.localizedStandardCompare($1.region.name) == .orderedAscending }
    }
}

/// A node on the map.
/// A marker: one node, or a cluster of nodes too close together to tell apart at this zoom.
final class NodeAnnotation: MLNPointAnnotation {
    var pointID = ""
    var kind = MapContent.Point.Kind.person
    var isContact = false
    /// nodes in it when it's a cluster (0: a single node)
    var count = 0
    var bounds: (south: Double, west: Double, north: Double, east: Double)?
    /// the node whose card is open: drawn bigger, in full colour, ringed
    var selected = false

    var imageID: String { count > 0 ? "cluster-\(kind.rawValue)-\(count)" : "\(kind.rawValue)-\(isContact)-\(selected)" }
}

struct MapLibreView: UIViewRepresentable {
    let points: [MapContent.Point]
    let route: [Position]
    /// a node's links to its neighbours, drawn thinner and paler than a route
    let links: [[Position]]
    let clustered: Bool
    let focus: MapFocus?
    @Binding var selection: String?
    /// the card over the bottom of the map: the centre is worked out above it
    let bottomInset: CGFloat
    let onArea: (OfflineRegion) -> Void

    func makeUIView(context: Context) -> MLNMapView {
        let dark = context.environment.colorScheme == .dark
        let v = MLNMapView(frame: .zero, styleURL: MapLibreMaps.style(dark: dark))
        context.coordinator.dark = dark
        v.delegate = context.coordinator
        v.showsScale = true
        v.scaleBarUsesMetricSystem = true
        v.isRotateEnabled = false
        v.isPitchEnabled = false
        v.automaticallyAdjustsContentInset = false
        // start where asked (a map made for "Show on map" opens there), else over Poland
        let start = focus?.position ?? Position(latitude: 52.0, longitude: 19.5)
        v.setCenter(CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude), zoomLevel: focus == nil ? 5.3 : 11, animated: false)
        context.coordinator.lastFocus = focus?.serial
        context.coordinator.lastSelection = selection
        context.coordinator.zoom = Int(v.zoomLevel)
        // a tap on the map itself (not a marker) closes the card: after the map's own double tap fails,
        // so zooming in with a double tap doesn't
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for g in v.gestureRecognizers ?? [] where (g as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 { tap.require(toFail: g) }
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ v: MLNMapView, context: Context) {
        context.coordinator.parent = self
        // light or dark, as the phone is (markers and lines stay: they aren't part of the style)
        let dark = context.environment.colorScheme == .dark
        if dark != context.coordinator.dark {
            context.coordinator.dark = dark
            v.styleURL = MapLibreMaps.style(dark: dark)
        }
        context.coordinator.sync(v)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreView
        var annotations: [String: NodeAnnotation] = [:]
        var routeLine: MLNPolyline?
        var lastRoute: [Position] = []
        var linkLines: [MLNPolyline] = []
        var lastLinks: [[Position]] = []
        /// the focus last applied (its serial: the same place asked for again moves the map again)
        var lastFocus: Int?
        var lastSelection: String?
        /// the node just selected, until the map has centred on it above the card (whose height comes
        /// a moment later, and moving the inset would cut that move short)
        var easeTarget: CLLocationCoordinate2D?
        /// when the map last selected a marker or cluster: a tap on the map near that moment was on it
        var markerSelected: CFTimeInterval = 0
        /// the whole zoom level the clusters were made for
        var zoom = 5
        /// drawn with the dark style
        var dark = false

        init(_ parent: MapLibreView) { self.parent = parent }

        func sync(_ v: MLNMapView) {
            let insetChanged = abs(v.contentInset.bottom - parent.bottomInset) > 0.5
            if insetChanged {
                v.setContentInset(UIEdgeInsets(top: 0, left: 0, bottom: parent.bottomInset, right: 0), animated: easeTarget == nil, completionHandler: nil)
            }
            let marks = parent.clustered
                ? MapClustering.marks(parent.points, zoom: zoom, apart: parent.selection.map { [$0] } ?? [])
                : parent.points.map { MapMark.point($0) }
            let wanted = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let gone = annotations.filter { wanted[$0.key] == nil }
            if !gone.isEmpty {
                v.removeAnnotations(Array(gone.values))
                for k in gone.keys { annotations[k] = nil }
            }
            var added: [NodeAnnotation] = []
            for (id, m) in wanted {
                let a = NodeAnnotation()
                a.pointID = id
                a.coordinate = CLLocationCoordinate2D(latitude: m.position.latitude, longitude: m.position.longitude)
                switch m {
                case .point(let p):
                    a.kind = p.kind; a.isContact = p.isContact; a.title = p.name; a.selected = p.id == parent.selection
                case .cluster(let c):
                    a.kind = c.kind; a.isContact = true; a.count = c.count; a.title = String(localized: "\(c.count) nodes")
                    a.bounds = (c.south, c.west, c.north, c.east)
                }
                if let old = annotations[id] {
                    if old.imageID == a.imageID {
                        // the same marker: move or rename it in place
                        if old.coordinate.latitude != a.coordinate.latitude || old.coordinate.longitude != a.coordinate.longitude { old.coordinate = a.coordinate }
                        if old.title != a.title { old.title = a.title }
                        continue
                    }
                    // a different marker: replace it so the map asks for the new image
                    v.removeAnnotation(old)
                }
                annotations[id] = a
                added.append(a)
            }
            if !added.isEmpty { v.addAnnotations(added) }

            if parent.route != lastRoute {
                if let r = routeLine { v.removeAnnotation(r); routeLine = nil }
                var coords = parent.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                if coords.count > 1 {
                    let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                    v.addAnnotation(line)
                    routeLine = line
                    fit(v, coords)
                }
                lastRoute = parent.route
            }

            if parent.links != lastLinks {
                v.removeAnnotations(linkLines)
                linkLines = parent.links.compactMap { line in
                    var coords = line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    return coords.count > 1 ? MLNPolyline(coordinates: &coords, count: UInt(coords.count)) : nil
                }
                v.addAnnotations(linkLines)
                // just turned on: the node and its neighbours on screen
                if lastLinks.isEmpty, !parent.links.isEmpty {
                    fit(v, parent.links.flatMap { $0 }.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                }
                lastLinks = parent.links
            }

            if let f = parent.focus, f.serial != lastFocus {
                easeTarget = nil
                center(v, on: f)
            } else if parent.selection != lastSelection {
                // a marker tapped (or picked): ease to it, zooming in but never out
                easeTarget = parent.selection.flatMap { annotations[$0] }.flatMap { $0.count == 0 ? $0.coordinate : nil }
                if let c = easeTarget { v.setCenter(c, zoomLevel: max(v.zoomLevel, 11), animated: true) }
            } else if insetChanged, let c = easeTarget {
                // the card's height came in: centre above it, once
                v.setCenter(c, zoomLevel: max(v.zoomLevel, 11), animated: true)
                easeTarget = nil
            }
            lastSelection = parent.selection
        }

        /// Centres on a focus once the map has a size: one just made has none until its first layout, and a
        /// move asked for before that is lost.
        func center(_ v: MLNMapView, on f: MapFocus, tries: Int = 0) {
            guard v.bounds.width > 100, v.bounds.height > 100 else {
                if tries < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak v] in
                        if let self, let v, self.parent.focus == f { self.center(v, on: f, tries: tries + 1) }
                    }
                }
                return
            }
            lastFocus = f.serial
            v.setCenter(CLLocationCoordinate2D(latitude: f.position.latitude, longitude: f.position.longitude),
                        zoomLevel: f.zoom ?? max(v.zoomLevel, 11), animated: tries == 0)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            // a tap on a marker is the map's (it selects it, just before or after this); anywhere else
            // closes the card. Look once both have run.
            let at = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.parent.selection != nil, abs(self.markerSelected - at) > 0.4 else { return }
                self.parent.selection = nil
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The whole route on screen, clear of the tab bar below. A map just made has no size yet: wait
        /// for its first layout.
        func fit(_ v: MLNMapView, _ coords: [CLLocationCoordinate2D], tries: Int = 0) {
            guard v.bounds.width > 100, v.bounds.height > 100 else {
                if tries < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak v] in
                        if let self, let v { self.fit(v, coords, tries: tries + 1) }
                    }
                }
                return
            }
            var c = coords
            v.setVisibleCoordinates(&c, count: UInt(c.count), edgePadding: UIEdgeInsets(top: 60, left: 50, bottom: 50, right: 50), animated: tries == 0)
        }

        // MARK: MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let a = annotation as? NodeAnnotation else { return nil }
            if let image = mapView.dequeueReusableAnnotationImage(withIdentifier: a.imageID) { return image }
            let image = a.count > 0 ? Self.cluster(a.kind, count: a.count) : Self.marker(a.kind, contact: a.isContact, selected: a.selected)
            return MLNAnnotationImage(image: image, reuseIdentifier: a.imageID)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            // the card shows what's selected, and the marker is redrawn for it: MapLibre's own selection
            // would be lost when it is, so it's let go at once (and a line tapped isn't kept selected)
            mapView.deselectAnnotation(annotation, animated: false)
            guard let a = annotation as? NodeAnnotation else { return }
            markerSelected = CACurrentMediaTime()
            if a.count > 0, let b = a.bounds {
                // a cluster: zoom in until it comes apart
                mapView.deselectAnnotation(a, animated: false)
                if b.north - b.south < 0.0005 && b.east - b.west < 0.0005 {
                    mapView.setCenter(a.coordinate, zoomLevel: max(mapView.zoomLevel + 2, 14), animated: true)
                } else {
                    var corners = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
                    mapView.setVisibleCoordinates(&corners, count: 2, edgePadding: UIEdgeInsets(top: 90, left: 70, bottom: 70, right: 70), animated: true)
                }
                return
            }
            if parent.selection != a.pointID {
                parent.selection = a.pointID
            } else {
                mapView.setCenter(a.coordinate, zoomLevel: max(mapView.zoomLevel, 11), animated: true)   // tapped again: back to it
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let b = mapView.visibleCoordinateBounds
            parent.onArea(OfflineRegion(name: "Map area", south: max(-85, b.sw.latitude), west: max(-180, b.sw.longitude),
                                        north: min(85, b.ne.latitude), east: min(180, b.ne.longitude)))
            // regroup at each whole zoom level
            let z = Int(mapView.zoomLevel)
            if z != zoom { zoom = z; sync(mapView) }
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            linkLines.contains { $0 === annotation } ? .tintColor.withAlphaComponent(0.5) : .tintColor
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            linkLines.contains { $0 === annotation } ? 1.5 : 3
        }

        // MARK: markers

        static func color(_ k: MapContent.Point.Kind) -> UIColor {
            switch k {
            case .person: .systemBlue
            case .repeater: .systemOrange
            case .room: .systemPurple
            case .sensor: .systemTeal
            case .home: .systemGreen
            }
        }

        /// A filled circle with the kind's symbol; nodes that aren't contacts are paler. The selected one is
        /// bigger, in full colour, with a white ring inside a ring of its colour.
        static func marker(_ k: MapContent.Point.Kind, contact: Bool, selected: Bool = false) -> UIImage {
            let size = CGSize(width: selected ? 36 : 26, height: selected ? 36 : 26)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let bounds = CGRect(origin: .zero, size: size)
                if selected {
                    color(k).withAlphaComponent(0.35).setFill()
                    UIBezierPath(ovalIn: bounds).fill()
                }
                let circle = UIBezierPath(ovalIn: bounds.insetBy(dx: selected ? 4 : 2, dy: selected ? 4 : 2))
                color(k).withAlphaComponent(contact || k == .home || selected ? 1 : 0.55).setFill()
                circle.fill()
                UIColor.white.setStroke()
                circle.lineWidth = selected ? 2.5 : 2
                circle.stroke()
                let config = UIImage.SymbolConfiguration(pointSize: selected ? 14 : 11, weight: .semibold)
                if let s = UIImage(systemName: MapContent.symbol(k), withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    s.draw(in: CGRect(x: (size.width - s.size.width) / 2, y: (size.height - s.size.height) / 2, width: s.size.width, height: s.size.height))
                }
            }
        }

        /// A cluster: the count on a circle in its most common kind's colour, inside a pale ring, a little
        /// bigger the more it holds.
        static func cluster(_ k: MapContent.Point.Kind, count: Int) -> UIImage {
            let d: CGFloat = count < 10 ? 34 : count < 50 ? 40 : 46
            let size = CGSize(width: d, height: d)
            return UIGraphicsImageRenderer(size: size).image { _ in
                color(k).withAlphaComponent(0.28).setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
                let inner = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5))
                color(k).setFill()
                inner.fill()
                UIColor.white.setStroke()
                inner.lineWidth = 2
                inner.stroke()
                let text = "\(count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: count < 100 ? 13 : 11, weight: .bold), .foregroundColor: UIColor.white]
                let t = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (d - t.width) / 2, y: (d - t.height) / 2), withAttributes: attrs)
            }
        }
    }
}
