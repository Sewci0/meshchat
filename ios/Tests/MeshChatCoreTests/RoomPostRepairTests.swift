import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// Room posts as stored before the text type was read right: the author's 4-byte key prefix in front of
// the text, decoded with U+FFFD for its invalid bytes (the two real ones are from a phone's database).

@Suite("Room post repair")
struct RoomPostRepairTests {
    /// How the old decoder stored a post: prefix and text decoded together.
    static func stored(_ prefix: [UInt8], _ text: String) -> String {
        String(decoding: Data(prefix) + Data(text.utf8), as: UTF8.self)
    }

    @Test func takesTheAuthorPrefixOff() throws {
        let a = try #require(RoomPostRepair.split(Self.stored([0x57, 0x22, 0xFD, 0xBA], "Chyba masz czas zle ustawiony")))
        #expect(a.text == "Chyba masz czas zle ustawiony")
        #expect(a.author == "5722")   // the bytes before the first one lost
        let b = try #require(RoomPostRepair.split("J\u{2}\u{FFFD}\u{FFFD}Test 3"))
        #expect(b.text == "Test 3")
        #expect(b.author == "4a02")
    }

    @Test func authorUnknownWhenItsFirstByteIsLost() throws {
        let r = try #require(RoomPostRepair.split(Self.stored([0xC0, 0x41, 0x42, 0x43], "zażółć")))
        #expect(r.text == "zażółć")
        #expect(r.author == nil)
    }

    @Test func validCharactersInThePrefixCountTheirBytes() throws {
        // 0xC4 0x85 is "ą": one character, two of the prefix's bytes
        let r = try #require(RoomPostRepair.split(Self.stored([0xC4, 0x85, 0x31, 0x32], "ok")))
        #expect(r.text == "ok")
        #expect(r.author == "c4853132")
    }

    @Test func leavesTooShortTextAlone() {
        #expect(RoomPostRepair.split("J") == nil)                       // a NUL in the prefix cut it here
        #expect(RoomPostRepair.split("J\u{2}\u{FFFD}\u{FFFD}") == nil)  // a prefix and no post
        #expect(RoomPostRepair.split("ab😀cd") == nil)                   // a character across the prefix's end
    }

    @Test func repairsOnlyRoomPosts() throws {
        let store = try Store.inMemory()
        let room = try #require(PublicKey(hex: String(repeating: "38", count: 32)))
        let heardRoom = try #require(PublicKey(hex: String(repeating: "39", count: 32)))
        let person = try #require(PublicKey(hex: String(repeating: "40", count: 32)))
        try store.save(RoomMembership(key: room.hex, left: false, admin: false))
        try store.save(HeardNode(key: heardRoom.hex, name: "Heard room", type: 3, latitude: nil, longitude: nil, firstHeard: .now,
                                 lastHeard: .now, snr: 0, rssi: 0, hops: 0, path: "", hashSize: 1, count: 1))
        func add(_ c: PublicKey, _ d: Direction, _ sender: String, _ text: String, author: String? = nil) throws {
            var m = Message(senderTimestamp: 1, conversation: .direct(c), direction: d, sender: sender, text: text,
                            status: d == .incoming ? .received : .sent)
            m.author = author
            _ = try store.insert(m)
        }
        try add(room, .incoming, "LUNA", "J\u{2}\u{FFFD}\u{FFFD}Test 3")
        try add(heardRoom, .incoming, "Heard room", "\u{FFFD}AB\u{FFFD}Hej")
        try add(room, .incoming, "Ala", "Already right", author: "4a02fdba")
        try add(room, .outgoing, "me", "Mine, as typed")
        try add(person, .incoming, "Bob", "A plain DM")

        #expect(try store.repairRoomPosts() == 2)
        let posts = try store.messages(in: .direct(room)) + store.messages(in: .direct(heardRoom)) + store.messages(in: .direct(person))
        #expect(posts.map(\.text) == ["Test 3", "Already right", "Mine, as typed", "Hej", "A plain DM"])
        #expect(posts.map(\.sender) == ["4a02", "Ala", "me", "Heard room", "Bob"])
        // (it runs once, as a migration: posts received since carry their author, and aren't touched)
    }
}
