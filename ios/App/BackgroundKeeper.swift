import CoreLocation
import MeshChatCore
import MeshChatUI
import Observation
import UIKit

/// Keeps MeshChat running in the background while it's connected to a radio over WiFi, so messages keep
/// arriving, notify, and the lock screen's status stays live.
///
/// iOS suspends an app soon after it leaves the screen, and its WiFi connection with it. Bluetooth
/// accessories have their own background mode; a TCP link to a radio on the LAN has none. The one fit
/// is location updates: started while the app is in front they go on in the background (iOS shows a
/// blue pill meanwhile), and while they run the app does. They're asked at the coarsest accuracy (cell
/// and WiFi, not GPS), so they cost little battery, and the positions are thrown away: nothing is
/// sent anywhere.
@MainActor
final class BackgroundKeeper: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()
    private weak var model: AppModel?
    private let manager = CLLocationManager()
    private var running = false

    func attach(_ model: AppModel) {
        self.model = model
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundKeeper.shared.update() }
        }
        observe()
        update()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.keepRunningInBackground
            _ = model.savedRadio
            _ = model.disconnectedByYou
        } onChange: {
            Task { @MainActor in
                BackgroundKeeper.shared.update()
                BackgroundKeeper.shared.observe()
            }
        }
    }

    /// Running only when it's wanted: a WiFi radio, the setting on, not disconnected on purpose.
    private func update() {
        guard let model else { return }
        let wifi = model.savedRadio.map { !$0.isBluetooth } ?? false
        let want = wifi && model.keepRunningInBackground && !model.disconnectedByYou
        if want { start() } else { stop() }
    }

    private func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // the answer comes back to locationManagerDidChangeAuthorization
        case .denied, .restricted:
            stop()
            model?.backgroundBlocked = true
        default:
            model?.backgroundBlocked = false
            // iOS lets location updates (and so the app) carry on in the background only if they started
            // with the app in front
            guard !running, UIApplication.shared.applicationState != .background else { return }
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            running = true
            model?.runsInBackground = true
        }
    }

    private func stop() {
        guard running else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        running = false
        model?.runsInBackground = false
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { update() }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}   // not kept

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
