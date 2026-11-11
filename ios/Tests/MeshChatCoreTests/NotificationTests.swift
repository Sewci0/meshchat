import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// What notifies and how: the defaults per kind of conversation, mentions, muting, old news and the
// reconnect backlog, the app icon's number.

private let now = Date(timeIntervalSince1970: 1_794_000_000)
private let alice = PublicKey(Data(repeating: 0xB2, count: 32))!

private func message(_ text: String, in c: ConversationID = .channel(0), from sender: String? = "Ala", id: Int64 = 7,
                     sentAgo: TimeInterval = 5) -> Message {
    var m = Message(senderTimestamp: UInt32(now.timeIntervalSince1970 - sentAgo), conversation: c, direction: .incoming,
                    sender: sender, text: text, status: .received)
    m.id = id
    return m
}

private func context(_ kind: ConversationKind, title: String = "Public", visible: ConversationID? = nil, backlog: Bool = false,
                     canReply: Bool = true) -> NotificationContext {
    NotificationContext(myName: "MrE", kind: kind, title: title, canReply: canReply, visible: visible, isBacklog: backlog, now: now)
}

@Suite("Notifications")
struct NotificationTests {
    @Test func channelsNotifyOnlyMentionsByDefault() {
        let s = NotificationSettings()
        #expect(NotificationPolicy.decide(message("hej wszystkim"), settings: s, context: context(.channel)) == nil)
        let p = NotificationPolicy.decide(message("@[MrE] jesteś?"), settings: s, context: context(.channel))
        #expect(p?.isMention == true)
        #expect(p?.title == "Ala" && p?.subtitle == "Public")
        #expect(p?.passive == false && p?.sound == true && p?.relevance == 1)
        #expect(p?.identifier == "msg-7" && p?.thread == "chan:0")
    }

    @Test func directMessagesAndRoomsNotifyEverything() {
        let s = NotificationSettings()
        let dm = NotificationPolicy.decide(message("hej", in: .direct(alice)), settings: s, context: context(.direct, title: "Ala"))
        #expect(dm?.title == "Ala" && dm?.subtitle == nil && dm?.relevance == 1 && dm?.category == NotificationPlan.replyCategory)
        let room = NotificationPolicy.decide(message("post", in: .direct(alice), from: "Ola"), settings: s, context: context(.room, title: "LUNA"))
        #expect(room?.title == "Ola" && room?.subtitle == "LUNA" && room?.relevance == 0.6)
        // a read-only room offers Mark as read but no Reply
        let readOnly = NotificationPolicy.decide(message("post", in: .direct(alice)), settings: s, context: context(.room, canReply: false))
        #expect(readOnly?.category == NotificationPlan.readOnlyCategory)
    }

    @Test func channelChatterIsQuietWhenTurnedOn() {
        var s = NotificationSettings()
        s.set(.all, for: .channel(0))
        let p = NotificationPolicy.decide(message("hej wszystkim"), settings: s, context: context(.channel))
        #expect(p?.passive == true && p?.sound == false && p?.relevance == 0.3)
    }

    @Test func offMutedAndOnScreenDontNotify() {
        var s = NotificationSettings()
        let c = ConversationID.direct(alice)
        s.set(.off, for: c)
        #expect(NotificationPolicy.decide(message("hej", in: c), settings: s, context: context(.direct)) == nil)
        s.set(nil, for: c)
        s.mute(c, until: now.addingTimeInterval(3600))
        #expect(NotificationPolicy.decide(message("hej", in: c), settings: s, context: context(.direct)) == nil)
        // the mute runs out by itself
        #expect(s.effectiveLevel(for: c, kind: .direct, now: now.addingTimeInterval(3601)) == .all)
        s.mute(c, until: nil)
        #expect(s.perConversation.isEmpty)   // back to the default leaves nothing behind
        #expect(NotificationPolicy.decide(message("hej", in: c), settings: s, context: context(.direct, visible: c)) == nil)
        s.enabled = false
        #expect(NotificationPolicy.decide(message("hej", in: c), settings: s, context: context(.direct)) == nil)
    }

    @Test func oldNewsIsQuietButClocksAheadAreTrusted() {
        let s = NotificationSettings()
        let c = ConversationID.direct(alice)
        let old = NotificationPolicy.decide(message("hej", in: c, sentAgo: 3600), settings: s, context: context(.direct))
        #expect(old?.passive == true && old?.sound == false)
        let ahead = NotificationPolicy.decide(message("hej", in: c, sentAgo: -600), settings: s, context: context(.direct))
        #expect(ahead?.passive == false)
    }

    @Test func hiddenTextSaysWhatItIs() {
        var s = NotificationSettings()
        s.showText = false
        #expect(NotificationPolicy.decide(message("@[MrE] sekret"), settings: s, context: context(.channel))?.body == "Mentioned you")
        #expect(NotificationPolicy.decide(message("sekret", in: .direct(alice)), settings: s, context: context(.direct))?.body == "New message")
    }

    @Test func mentionsMatchAcrossAppsSpelling() {
        #expect(Mentions.names(in: "@[Ala] i @[Ola 🇵🇱] hej") == ["Ala", "Ola 🇵🇱"])
        #expect(Mentions.mentions("MrE", in: "@[mre] hej"))
        #expect(Mentions.mentions("Nareli_SCI👑", in: "@[Nareli_SCI👑\u{FE0F}] ok"))         // emoji variation selector
        #expect(Mentions.mentions("Zośka", in: "@[Zos\u{301}ka] hej"))                     // decomposed accent
        #expect(!Mentions.mentions("MrE", in: "MrE without brackets"))
        #expect(!Mentions.mentions("", in: "@[] hej"))
        #expect(!Mentions.mentions("Ala", in: "@[Ala"))                                    // unclosed
    }

    @Test func theBacklogFoldsIntoOnePerConversation() {
        let s = NotificationSettings()
        var b = BacklogCoalescer()
        let c = ConversationID.direct(alice)
        for (i, t) in ["one", "two", "three"].enumerated() {
            b.add(NotificationPolicy.decide(message(t, in: c, id: Int64(10 + i)), settings: s, context: context(.direct, backlog: true))!)
        }
        b.add(NotificationPolicy.decide(message("@[MrE] hej", id: 20), settings: s, context: context(.channel, backlog: true))!)
        let out = b.flush()
        #expect(out.count == 2 && b.isEmpty)
        #expect(out[0].body == "three" && out[0].earlier == 2 && out[0].fullBody == "three\n+2 earlier messages")
        #expect(out[0].sound && !out[1].sound)   // one sound for the whole burst
    }

    @Test func theIconCountsWhatNotifiesEverything() {
        var s = NotificationSettings()
        let dm = ConversationID.direct(alice)
        let unread: [(ConversationID, ConversationKind)] = [(dm, .direct), (.channel(0), .channel), (.channel(1), .channel)]
        #expect(s.badgeCount(unread: unread, now: now) == 1)       // channels default to mentions only
        s.set(.all, for: .channel(1))
        #expect(s.badgeCount(unread: unread, now: now) == 2)
        s.mute(dm, until: .distantFuture)
        #expect(s.badgeCount(unread: unread, now: now) == 1)
        s.badge = false
        #expect(s.badgeCount(unread: unread, now: now) == 0)
    }

    @Test func settingsSurviveARelaunch() throws {
        var s = NotificationSettings()
        s.channelDefault = .off
        s.set(.all, for: .listened("#test"))
        s.mute(.direct(alice), until: now)
        let back = try JSONDecoder().decode(NotificationSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        s.forget(.listened("#test"))
        #expect(s.perConversation["watch:#test"] == nil)
    }
}
