import MeshChatCore
import MeshChatUI
import SwiftUI
import UserNotifications

@main
struct MeshChatApp: App {
    @State private var model: AppModel?
    @State private var maps = MapLibreMaps()
    /// the demo (trying MeshChat without a radio), shown instead of your radio while it's on; `-demo`
    /// starts in it
    @State private var demo = DemoSwitch(startNow: ProcessInfo.processInfo.arguments.contains("-demo"))
    @Environment(\.scenePhase) private var phase

    init() {
        // before launch finishes, so a notification that launched the app (a tap, or Reply from the lock
        // screen) reaches it
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        let m = try? AppModel.live()
        _model = State(initialValue: m)
        if let m {
            Notifier.shared.attach(m)
            LiveStatus.shared.attach(m)   // the radio's status on the lock screen
            BackgroundKeeper.shared.attach(m)   // stays connected over WiFi in the background
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                let shown = demo.model ?? model
                RootView(model: shown, maps: maps)
                    .id(ObjectIdentifier(shown))   // fresh screens when switching to or from the demo
                    .environment(demo)
                    // ask for notifications once there's a radio to hear from, not on first launch
                    .onChange(of: model.isConnected) { _, connected in
                        if connected, model.notificationPermission == .notAsked { Task { await Notifier.shared.askPermission() } }
                    }
            } else {
                ContentUnavailableView("MeshChat couldn't open its storage", systemImage: "exclamationmark.triangle",
                                       description: Text("Restart the app. If it keeps happening, free some space on the device."))
            }
        }
        .onChange(of: phase) { _, p in
            // the answer may have changed in iOS Settings meanwhile
            if p == .active { Notifier.shared.refreshPermission(); Notifier.shared.updateBadge() }
        }
    }
}
