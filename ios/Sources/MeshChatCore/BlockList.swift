import Foundation
import MeshCoreKit

/// People you've blocked. Their messages are hidden on this iPhone: on channels and in rooms by the name
/// they post under, in direct messages by their key. They don't notify you. Nothing is sent: the mesh has
/// no blocking of its own, so they aren't told and their messages still reach others.
public struct BlockList: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public let name: String
        /// their key (hex), when they're a contact
        public let key: String?
        public var id: String { key ?? "name:" + name }
        public init(name: String, key: String?) { self.name = name; self.key = key }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func block(name: String, key: String?) {
        guard !isBlocked(name: name, key: key) else { return }
        entries.append(Entry(name: name, key: key))
    }

    public mutating func unblock(_ e: Entry) { entries.removeAll { $0 == e } }

    /// Blocked by key, or by name.
    public func isBlocked(name: String?, key: String?) -> Bool {
        entries.contains { e in
            (key != nil && e.key == key) || (name.map { !$0.isEmpty && $0 == e.name } ?? false)
        }
    }

    /// A message to hide: one received from someone blocked.
    public func hides(_ m: Message) -> Bool {
        guard m.direction == .incoming else { return false }
        if case .direct(let k) = m.conversation, isBlocked(name: nil, key: k.hex) { return true }
        return isBlocked(name: m.sender, key: nil)
    }

    /// A direct conversation with someone blocked.
    public func hides(_ c: ConversationID) -> Bool {
        if case .direct(let k) = c { return isBlocked(name: nil, key: k.hex) }
        return false
    }
}
