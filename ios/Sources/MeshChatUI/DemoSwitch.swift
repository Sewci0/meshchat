import Foundation
import Observation

/// Which model the app shows: yours, or the demo's (trying MeshChat without a radio). The app keeps yours
/// running underneath, so leaving the demo goes straight back to your radio.
@MainActor @Observable
public final class DemoSwitch {
    /// the demo, while it's on
    public private(set) var model: AppModel?

    /// - startNow: open in the demo (the `-demo` launch argument: App Store review notes and screenshots)
    public init(startNow: Bool = false) {
        if startNow { start() }
    }

    public func start() {
        guard model == nil else { return }
        model = AppModel.demo()
    }

    public func leave() {
        let m = model
        model = nil
        Task { await m?.engine.disconnect() }
    }
}
