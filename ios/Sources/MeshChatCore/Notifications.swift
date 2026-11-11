import Foundation
import MeshCoreKit

// What notifies, decided in one place: pure, so it's tested without iOS. The app turns a plan into a
// notification; nothing here leaves the device.

/// How much of a conversation notifies.
public enum NotifyLevel: String, Codable, Sendable, CaseIterable {
    case all, mentions, off

    public var label: String {
        switch self {
        case .all: String(localized: "All messages")
        case .mentions: String(localized: "Mentions only")
        case .off: String(localized: "Off")
        }
    }
}

/// The kinds of conversation, which have different defaults.
public enum ConversationKind: String, Sendable {
    case direct, room, channel, listened

    /// for Focus filters ("filterCriteria")
    public var filter: String {
        switch self {
        case .direct: "dm"
        case .room: "room"
        case .channel, .listened: "channel"
        }
    }
}

/// One conversation's own choice, over the default for its kind.
public struct ConversationNotify: Codable, Sendable, Equatable {
    /// nil: the default for its kind
    public var level: NotifyLevel?
    /// silent until then (`.distantFuture`: until turned back on)
    public var mutedUntil: Date?

    public init(level: NotifyLevel? = nil, mutedUntil: Date? = nil) { self.level = level; self.mutedUntil = mutedUntil }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    /// the master switch
    public var enabled = true
    /// the message in the notification (off: "New message")
    public var showText = true
    public var sound = true
    /// unread conversations on the app icon
    public var badge = true
    public var channelDefault: NotifyLevel = .mentions
    public var roomDefault: NotifyLevel = .all
    /// by `ConversationID.description`
    public var perConversation: [String: ConversationNotify] = [:]

    public init() {}

    public func defaultLevel(_ kind: ConversationKind) -> NotifyLevel {
        switch kind {
        case .direct: .all
        case .room: roomDefault
        case .channel, .listened: channelDefault
        }
    }

    /// The conversation's own level, or its kind's default.
    public func level(for c: ConversationID, kind: ConversationKind) -> NotifyLevel {
        perConversation[c.description]?.level ?? defaultLevel(kind)
    }

    public func mutedUntil(_ c: ConversationID, now: Date = .now) -> Date? {
        guard let u = perConversation[c.description]?.mutedUntil, u > now else { return nil }
        return u
    }

    /// What actually applies now: off while muted.
    public func effectiveLevel(for c: ConversationID, kind: ConversationKind, now: Date = .now) -> NotifyLevel {
        mutedUntil(c, now: now) != nil ? .off : level(for: c, kind: kind)
    }

    /// nil: back to the default.
    public mutating func set(_ level: NotifyLevel?, for c: ConversationID) {
        update(c) { $0.level = level }
    }

    /// nil: unmute.
    public mutating func mute(_ c: ConversationID, until: Date?) {
        update(c) { $0.mutedUntil = until }
    }

    /// When a conversation goes (a channel's slot is reused by the next channel joined).
    public mutating func forget(_ c: ConversationID) { perConversation[c.description] = nil }

    private mutating func update(_ c: ConversationID, _ change: (inout ConversationNotify) -> Void) {
        var n = perConversation[c.description] ?? ConversationNotify()
        change(&n)
        perConversation[c.description] = n.level == nil && n.mutedUntil == nil ? nil : n
    }

    /// The app icon's number: unread conversations that notify every message. Channels left on
    /// "mentions only" stay off it, or a busy channel would keep it lit for good.
    public func badgeCount(unread: [(ConversationID, ConversationKind)], now: Date = .now) -> Int {
        guard enabled, badge else { return 0 }
        return unread.filter { effectiveLevel(for: $0.0, kind: $0.1, now: now) == .all }.count
    }
}

/// MeshCore mentions: `@[Name]` in the text. Names are compared the way people expect, not byte for
/// byte: case, Unicode normalisation and emoji variation selectors differ between apps.
public enum Mentions {
    public static func names(in text: String) -> [String] {
        var out: [String] = [], rest = text[...]
        while let open = rest.range(of: "@[") {
            guard let close = rest[open.upperBound...].firstIndex(of: "]") else { break }
            out.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    public static func mentions(_ name: String, in text: String) -> Bool {
        let me = normalized(name)
        return !me.isEmpty && names(in: text).contains { normalized($0) == me }
    }

    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{FE0F}", with: "")
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}

/// What the app knows that the message doesn't.
public struct NotificationContext: Sendable {
    public var myName: String?
    public var kind: ConversationKind
    /// the conversation's name (the channel, room or person)
    public var title: String
    /// a reply can be sent from the notification (not a listened channel or a read-only room)
    public var canReply: Bool
    /// the conversation open on screen with the app in front
    public var visible: ConversationID?
    /// fetched from the radio's queue on reconnecting, not heard just now
    public var isBacklog: Bool
    public var now: Date

    public init(myName: String?, kind: ConversationKind, title: String, canReply: Bool, visible: ConversationID?,
                isBacklog: Bool, now: Date = .now) {
        self.myName = myName; self.kind = kind; self.title = title; self.canReply = canReply
        self.visible = visible; self.isBacklog = isBacklog; self.now = now
    }
}

/// One notification to post.
public struct NotificationPlan: Equatable, Sendable {
    public static let replyCategory = "chat", readOnlyCategory = "readonly"

    public let identifier: String
    /// groups a conversation's notifications
    public let thread: String
    public let messageID: Int64
    public let title: String
    /// the conversation, when the title is its sender (channels and rooms)
    public let subtitle: String?
    public let body: String
    public let category: String
    public var sound: Bool
    /// delivered quietly: no banner or sound, into Notification Centre (channel chatter, old news)
    public var passive: Bool
    /// how much it matters (0–1), for the order in a stack and Scheduled Summary
    public let relevance: Double
    public let isMention: Bool
    public let sender: String?
    public let kind: ConversationKind
    /// earlier messages folded into this one (the reconnect backlog)
    public var earlier = 0

    /// The body with what was folded into it.
    public var fullBody: String {
        guard earlier > 0 else { return body }
        return body + "\n" + (earlier == 1 ? String(localized: "+1 earlier message") : String(localized: "+\(earlier) earlier messages"))
    }
}

public enum NotificationPolicy {
    /// older than this (by the sender's clock) and it's old news: delivered quietly
    public static let staleAfter: TimeInterval = 15 * 60

    /// Whether and how a new incoming message notifies.
    public static func decide(_ m: Message, settings: NotificationSettings, context: NotificationContext) -> NotificationPlan? {
        guard settings.enabled, m.direction == .incoming, let id = m.id else { return nil }
        guard context.visible != m.conversation else { return nil }   // being read right now
        let level = settings.effectiveLevel(for: m.conversation, kind: context.kind, now: context.now)
        let mention = context.myName.map { Mentions.mentions($0, in: m.text) } ?? false
        switch level {
        case .off: return nil
        case .mentions: if context.kind != .direct && !mention { return nil }
        case .all: break
        }
        // a sender's clock can be wrong (or missing): only trust it when it isn't ahead of ours
        let age = m.senderTimestamp.map { context.now.timeIntervalSince1970 - Double($0) }
        let stale = age.map { $0 > staleAfter } ?? false
        let chatter = (context.kind == .channel || context.kind == .listened) && !mention
        let passive = stale || chatter
        let group = context.kind != .direct
        return NotificationPlan(
            identifier: "msg-\(id)", thread: m.conversation.description, messageID: id,
            title: group ? (m.sender ?? context.title) : context.title,
            subtitle: group ? context.title : nil,
            body: settings.showText ? m.text : (mention ? String(localized: "Mentioned you") : String(localized: "New message")),
            category: context.canReply ? NotificationPlan.replyCategory : NotificationPlan.readOnlyCategory,
            sound: settings.sound && !passive,
            passive: passive,
            relevance: mention || context.kind == .direct ? 1 : context.kind == .room ? 0.6 : 0.3,
            isMention: mention, sender: m.sender, kind: context.kind)
    }
}

/// The reconnect backlog, one notification per conversation: its newest message, "+N earlier", and
/// only the first of them makes a sound.
public struct BacklogCoalescer: Sendable {
    private var pending: [String: NotificationPlan] = [:]
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func add(_ p: NotificationPlan) {
        guard var old = pending[p.thread] else {
            pending[p.thread] = p
            order.append(p.thread)
            return
        }
        let newer = p.messageID >= old.messageID
        var keep = newer ? p : old
        keep.earlier = old.earlier + p.earlier + 1
        // quiet only if every message in it was quiet
        keep.passive = old.passive && p.passive
        keep.sound = old.sound || p.sound
        old = keep
        pending[p.thread] = old
    }

    public mutating func flush() -> [NotificationPlan] {
        var out = order.compactMap { pending[$0] }
        pending = [:]; order = []
        var sounded = false
        for i in out.indices {
            if out[i].sound && !sounded { sounded = true } else { out[i].sound = false }
        }
        return out
    }
}
