import ActivityKit
import MeshChatCore
import MeshChatUI
import MeshCoreKit
import Observation
import UIKit

/// The radio's status, always in view: a Live Activity on the lock screen, in the Dynamic Island and
/// on the always-on display. Started when the app is in front (iOS allows no other time), then kept
/// current from the model while the app runs, in the background too (Bluetooth on its own, WiFi while
/// the app keeps itself running).
///
/// What it shows: the link and since when, the battery, unread conversations and the newest message
/// (or how your last one went), and the mesh at a glance: packets per 5 minutes over the hour, the
/// signal lately, repeaters heard directly, and your repeater.
@MainActor
final class LiveStatus {
    static let shared = LiveStatus()
    private weak var model: AppModel?
    private var activity: Activity<RadioActivityAttributes>?
    private var inBackground = false
    private var pending: Task<Void, Never>?
    private var lastSent: RadioActivityAttributes.ContentState?

    /// the link's state and when it last changed
    private var linkCase: State.Link?
    private var since: Date?
    /// the mesh numbers: from the packet log, at most once a minute (and every 5 minutes regardless)
    private var pulse: MeshPulse?
    private var pulseAt = Date.distantPast
    private var directRepeaters: Int?
    private var lastPackets = -1
    /// your repeater: from a day of the log, every 10 minutes
    private var repeater: (name: String, heard: Date?, quiet: Bool)?
    private var repeaterAt = Date.distantPast
    /// the radio's battery: asked every 10 minutes while connected
    private var batteryMv: Int?
    private var batteryAt = Date.distantPast

    typealias State = RadioActivityAttributes.ContentState

    func attach(_ model: AppModel) {
        self.model = model
        activity = Activity<RadioActivityAttributes>.activities.first   // one left from before this launch
        model.liveActivitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
        inBackground = UIApplication.shared.applicationState == .background
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveStatus.shared.scene(active: false) }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveStatus.shared.scene(active: true) }
        }
        observe()
        // the slow numbers roll on even when nothing arrives (the hour's buckets move, the battery drains)
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                await self.refreshSlow(force: true)
                await self.sync()
            }
        }
    }

    /// Follows what the status shows; each change re-arms it.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.connection
            _ = model.conversations
            _ = model.lastRead
            _ = model.notificationSettings
            _ = model.lockScreenStatus
            _ = model.savedRadio
            _ = model.packetVersion
            _ = model.runsInBackground
            _ = model.messageVersion
        } onChange: {
            Task { @MainActor in
                LiveStatus.shared.changed()
                LiveStatus.shared.observe()
            }
        }
    }

    private func changed() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await refreshSlow(force: false)
            await sync()
        }
    }

    private func scene(active: Bool) {
        inBackground = !active
        model?.liveActivitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
        // going to the background: say "paused" over WiFi (if it is) before iOS suspends the app
        let task = UIApplication.shared.beginBackgroundTask(withName: "Status")
        Task {
            await sync()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: the slow numbers

    private func refreshSlow(force: Bool) async {
        guard let model else { return }
        let now = Date.now
        let store = model.store
        // the mesh: on new packets at most once a minute, or when asked
        if force || pulse == nil || (model.packetVersion != lastPackets && now.timeIntervalSince(pulseAt) >= 60) {
            lastPackets = model.packetVersion
            pulseAt = now
            let dir = model.directory
            (pulse, directRepeaters) = await Task.detached(priority: .utility) { () -> (MeshPulse, Int) in
                let packets = (try? store.recentPackets(since: now.addingTimeInterval(-3600))) ?? []
                let pulse = MeshPulse(packets: packets.map { ($0.date, $0.hops, $0.path, $0.hashSize, $0.snr) }, now: now)
                // repeaters heard directly lately, counted as the Repeaters tab counts them: IDs resolved to
                // known repeaters (a 1- and a 2-byte ID of one repeater are one), and their own adverts
                let a = RepeaterAnalysis(packets: packets, channelRoutes: [], directory: dir, days: 1, now: now)
                let n = a.list.filter { $0.lastDirect.map { now.timeIntervalSince($0) <= ReachCheck.recent } ?? false }.count
                return (pulse, n)
            }.value
        }
        // your repeater: a day of the log, every 10 minutes
        if now.timeIntervalSince(repeaterAt) >= 600 {
            repeaterAt = now
            let dir = model.directory
            repeater = await Task.detached(priority: .utility) { () -> (name: String, heard: Date?, quiet: Bool)? in
                let since = now.addingTimeInterval(-86400)
                let a = RepeaterAnalysis(packets: (try? store.recentPackets(since: since)) ?? [],
                                         channelRoutes: (try? store.channelRoutes(since: since)) ?? [], directory: dir, days: 1)
                guard let y = a.yours else { return nil }
                let s = a.summary(y.key)
                return (s.name, s.lastDirect, a.quiet(y.key, now: now) != nil)
            }.value
        }
        // the battery: a question to the radio, every 10 minutes while connected
        if model.isConnected, now.timeIntervalSince(batteryAt) >= 600 {
            batteryAt = now
            if let b = try? await model.engine.battery() {
                batteryMv = b.millivolts > 0 ? Int((Double(b.millivolts) / 50).rounded()) * 50 : nil
            }
        }
    }

    // MARK: the activity

    private func sync() async {
        guard let model, let radio = model.savedRadio else { await end(); return }
        guard model.lockScreenStatus, ActivityAuthorizationInfo().areActivitiesEnabled else { await end(); return }
        let attributes = RadioActivityAttributes(radio: radio.title, transport: radio.isBluetooth ? "Bluetooth" : "WiFi")
        let state = state(model, wifi: !radio.isBluetooth)
        // stale if no update comes: the app was ended, or WiFi stopped in the background
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(radio.isBluetooth ? 30 * 60 : 10 * 60),
                                      relevanceScore: state.unread > 0 ? 1 : 0.5)
        if let a = activity, a.activityState == .active || a.activityState == .stale, a.attributes.radio == attributes.radio,
           a.attributes.transport == attributes.transport {
            guard state != lastSent || a.activityState == .stale else { return }
            // ActivityKit's Activity isn't marked Sendable, though updating it from here is what it's for
            nonisolated(unsafe) let current = a
            await current.update(content)
            lastSent = state
            return
        }
        // none yet, ended (8 hours, or swiped away) or for another radio: start one, which iOS allows only
        // with the app in front
        guard UIApplication.shared.applicationState == .active else { return }
        await end()
        activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        lastSent = state
    }

    private func state(_ model: AppModel, wifi: Bool) -> State {
        #if DEBUG
        // screenshots of the connected status without a radio: launch with -demoLiveActivity (debug builds only)
        if ProcessInfo.processInfo.arguments.contains("-demoLiveActivity") { return Self.demo }
        #endif
        let link: State.Link = switch model.connection {
        // over WiFi in the background the link pauses, unless the app keeps itself running
        case .connected: inBackground && wifi && !model.runsInBackground ? .paused : .connected
        case .connecting: .connecting
        case .failed, .disconnected: .offline
        }
        // connected (or offline) since: when the link last changed case, paused or not
        let settled: State.Link = link == .paused ? .connected : link
        if settled != linkCase { linkCase = settled; since = .now }

        let (count, newest) = model.unreadSummary
        let showText = model.notificationSettings.showText
        let msg = newest.map { m -> State.Msg in
            let kind: State.Msg.Kind = switch model.kind(of: m.conversation) {
            case .direct: .direct
            case .room: .room
            case .channel, .listened: .channel
            }
            let mention = model.me.map { Mentions.mentions($0.name, in: m.text) } ?? false
            return State.Msg(from: Self.cut(m.sender ?? model.title(of: m.conversation), 24),
                             place: kind == .direct ? nil : Self.cut(model.title(of: m.conversation), 24),
                             text: showText ? Self.cut(m.text, 140) : (mention ? String(localized: "Mentioned you") : String(localized: "New message")),
                             at: m.date, kind: kind, mention: mention)
        }

        // your last message, for 10 minutes
        let sent = (try? model.store.outgoing(since: .now.addingTimeInterval(-600)))?.max { $0.date < $1.date }.map { m -> State.Sent in
            let (status, ok): (String, Bool?) = switch m.status {
            case .repeated: (String(localized: "heard by repeaters"), true)
            case .delivered: (String(localized: "delivered"), true)
            case .notHeard: (String(localized: "not heard"), false)
            case .noAck: (String(localized: "no receipt"), false)
            case .failed: (String(localized: "not sent"), false)
            case .sending: (String(localized: "sending"), nil)
            default: (String(localized: "sent"), nil)
            }
            return State.Sent(status: status, at: m.date, ok: ok)
        }

        let sf = model.me?.radio.spreadingFactor ?? 8
        return State(link: link, since: since, unread: count, msg: msg,
                     heardAt: pulse?.heardAt, rate: pulse?.rate, rateEnd: pulse?.rateEnd, perHour: pulse?.perHour,
                     snr: pulse?.snr, level: pulse?.snr.map { MeshPulse.level(snr: $0, spreadingFactor: sf) },
                     repeaters: directRepeaters,
                     rptName: repeater.map { Self.cut($0.name, 24) }, rptHeard: repeater?.heard, rptQuiet: repeater?.quiet,
                     batteryMv: batteryMv, sent: sent)
    }

    #if DEBUG
    static var demo: State {
        let now = Date.now
        return State(link: .connected, since: now.addingTimeInterval(-2 * 3600 - 300), unread: 3,
                     msg: State.Msg(from: "Ania", place: "Public",
                                    text: String(localized: "Anyone hearing the new repeater on the hill? I get it at +6 dB from the east side.", comment: "Demo chat message"),
                                    at: now.addingTimeInterval(-240), kind: .channel, mention: true),
                     heardAt: now.addingTimeInterval(-50), rate: [3, 5, 2, 8, 12, 6, 2, 1, 4, 9, 5, 3], rateEnd: now.addingTimeInterval(120),
                     perHour: 60, snr: 7, level: 3, repeaters: 4, rptName: "Olsztyn Jura RPT", rptHeard: now.addingTimeInterval(-180),
                     rptQuiet: false, batteryMv: 3950, sent: nil)
    }
    #endif

    /// At most `n` characters, with an ellipsis when cut (the state has a size limit).
    private static func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    private func end() async {
        for a in Activity<RadioActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        activity = nil
        lastSent = nil
    }
}
