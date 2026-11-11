import Intents
import MeshChatCore
import MeshChatUI
import UIKit
import UserNotifications

/// Local notifications, made on the phone from what the radio hears (no server, nothing leaves the
/// device). `NotificationPolicy` decides; this posts, groups by conversation, answers the lock screen's
/// Reply and Mark as read, clears what's been read and keeps the app icon's number.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private weak var model: AppModel?
    private var backlog = BacklogCoalescer()
    private var flushTask: Task<Void, Never>?

    static let replyAction = "reply", readAction = "read"

    func attach(_ model: AppModel) {
        self.model = model
        registerCategories()
        model.onIncoming = { [weak self] m, backlog in self?.incoming(m, backlog: backlog) }
        model.onRead = { [weak self] c in self?.clear(c) }
        model.onNotificationSettings = { [weak self] in self?.updateBadge() }
        model.askNotificationPermission = { [weak self] in await self?.askPermission() }
        refreshPermission()
    }

    // MARK: permission

    /// iOS shows the question once; later calls return the answer given.
    func askPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings])
        refreshPermission()
    }

    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let p: AppModel.NotificationPermission = switch s.authorizationStatus {
            case .notDetermined: .notAsked
            case .denied: .denied
            default: .allowed
            }
            Task { @MainActor in Notifier.shared.model?.notificationPermission = p }
        }
    }

    // MARK: posting

    private func incoming(_ m: Message, backlog isBacklog: Bool) {
        defer { updateBadge() }
        guard let model else { return }
        let active = UIApplication.shared.applicationState == .active
        let context = model.notificationContext(for: m, backlog: isBacklog, appActive: active)
        guard let plan = NotificationPolicy.decide(m, settings: model.notificationSettings, context: context) else { return }
        guard isBacklog else { Task { await post(plan) }; return }
        // what waited on the radio comes in a burst: one notification per conversation, once it's all in
        backlog.add(plan)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            for p in backlog.flush() { await post(p) }
        }
    }

    private func post(_ p: NotificationPlan) async {
        let content = UNMutableNotificationContent()
        content.title = p.title
        if let s = p.subtitle { content.subtitle = s }
        content.body = p.fullBody
        content.threadIdentifier = p.thread                 // one stack per conversation
        content.targetContentIdentifier = p.thread
        content.categoryIdentifier = p.category             // Reply and Mark as read
        content.userInfo = ["message": String(p.messageID), "sender": p.sender ?? ""]
        content.sound = p.sound ? .default : nil
        content.interruptionLevel = p.passive ? .passive : .active
        content.relevanceScore = p.relevance
        content.filterCriteria = p.kind.filter              // for Focus filters
        // a Communication Notification (the sender's picture, Focus "allowed people") when the app has
        // that capability; a plain one otherwise
        let final: UNNotificationContent = (try? await communication(p, content)) ?? content
        let request = UNNotificationRequest(identifier: p.identifier, content: final, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The message as Siri sees it: who sent it, where, with a picture. Donating it is what lets iOS show
    /// the sender's avatar and treat them as a person (for Focus); it stays on the device.
    private func communication(_ p: NotificationPlan, _ content: UNMutableNotificationContent) async throws -> UNNotificationContent {
        let group = p.kind != .direct
        let name = group ? (p.sender ?? p.title) : p.title
        let sender = INPerson(personHandle: INPersonHandle(value: name, type: .unknown), nameComponents: nil, displayName: name,
                              image: Self.avatar(name), contactIdentifier: nil, customIdentifier: name)
        let me = INPerson(personHandle: INPersonHandle(value: model?.me?.name ?? "me", type: .unknown), nameComponents: nil,
                          displayName: model?.me?.name, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
        let intent = INSendMessageIntent(recipients: group ? [me] : nil, outgoingMessageType: .outgoingMessageText, content: p.fullBody,
                                         speakableGroupName: group ? INSpeakableString(spokenPhrase: p.subtitle ?? p.title) : nil,
                                         conversationIdentifier: p.thread, serviceName: "MeshChat", sender: sender, attachments: nil)
        if group { intent.setImage(Self.avatar(p.subtitle ?? p.title, symbol: p.kind == .room ? "person.3.fill" : "number"), forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try await interaction.donate()
        return try content.updating(from: intent)
    }

    /// Initials (or a symbol) on the same colour the app gives that name.
    static func avatar(_ name: String, symbol: String? = nil) -> INImage? {
        let hue = CGFloat(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let size = CGSize(width: 120, height: 120)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(hue: hue, saturation: 0.25, brightness: 0.92, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let ink = UIColor(hue: hue, saturation: 0.6, brightness: 0.4, alpha: 1)
            if let symbol, let s = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold))?
                .withTintColor(ink, renderingMode: .alwaysOriginal) {
                s.draw(at: CGPoint(x: (size.width - s.size.width) / 2, y: (size.height - s.size.height) / 2))
            } else {
                let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
                let text = (letters.isEmpty ? "?" : letters) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46, weight: .semibold), .foregroundColor: ink]
                let t = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2), withAttributes: attrs)
            }
        }
        return image.pngData().map { INImage(imageData: $0) }
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: String(localized: "Reply"), options: [.authenticationRequired],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Message"))
        let read = UNNotificationAction(identifier: Self.readAction, title: String(localized: "Mark as read"), options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        let chat = UNNotificationCategory(identifier: NotificationPlan.replyCategory, actions: [reply, read], intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: String(localized: "New message"), options: [.hiddenPreviewsShowTitle])
        let readOnly = UNNotificationCategory(identifier: NotificationPlan.readOnlyCategory, actions: [read], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: String(localized: "New message"), options: [.hiddenPreviewsShowTitle])
        UNUserNotificationCenter.current().setNotificationCategories([chat, readOnly])
    }

    // MARK: read, badge

    /// A conversation was read here: its notifications go, and the number on the icon follows.
    private func clear(_ c: ConversationID) {
        let thread = c.description
        UNUserNotificationCenter.current().getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
        updateBadge()
    }

    func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(model?.badgeCount ?? 0)
    }

    // MARK: answering

    /// What was tapped on a notification: open the conversation, mark it read, or send the reply typed
    /// on the lock screen (reconnecting first if the link dropped in the background).
    func respond(action: String, text: String?, thread: String, messageID: Int64?, sender: String?) async {
        guard let model, let c = ConversationID(thread) else { return }
        switch action {
        case Self.readAction:
            if let id = messageID { model.markRead(c, upTo: id) } else { model.markRead(c) }
        case Self.replyAction:
            guard var reply = text?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return }
            // in a channel, a reply says who it answers, as Reply in the app does
            if case .channel = c, let s = sender, !s.isEmpty { reply = "@[\(s)] " + reply }
            let task = UIApplication.shared.beginBackgroundTask(withName: "Reply")
            defer { UIApplication.shared.endBackgroundTask(task) }
            do {
                try await model.reply(reply, to: c)
                if let id = messageID { model.markRead(c, upTo: id) }
            } catch {
                await notSent(c, reply, why: "\(error)")
            }
        case UNNotificationDefaultActionIdentifier:
            model.open(c)
        default:
            break
        }
    }

    private func notSent(_ c: ConversationID, _ text: String, why: String) async {
        let content = UNMutableNotificationContent()
        content.title = model.map { String(localized: "Not sent to \($0.title(of: c))") } ?? String(localized: "Not sent to the conversation")
        content.body = String(localized: "“\(text)” — \(why) Open MeshChat to try again.")
        content.threadIdentifier = c.description
        content.sound = .default
        let request = UNNotificationRequest(identifier: "notsent-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// iOS's notification settings for MeshChat link here.
    func openSettings() {
        model?.tab = .settings
        model?.showNotificationSettings = true
    }
}

/// UserNotifications calls this from its own queue: it pulls out the plain values it needs, then hands
/// them to the main actor. Set at launch, so a tap that launched the app isn't missed.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    /// In front: banners for other conversations (the one on screen never notifies), quiet ones to the list.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let content = response.notification.request.content
        let thread = content.threadIdentifier
        let id = (content.userInfo["message"] as? String).flatMap { Int64($0) }
        let sender = content.userInfo["sender"] as? String
        await Notifier.shared.respond(action: action, text: text, thread: thread, messageID: id, sender: sender)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        Task { @MainActor in Notifier.shared.openSettings() }
    }
}
