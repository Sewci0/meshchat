import Foundation

/// One of a repeater's (or room server's) command-line commands. An admin runs them remotely; the node
/// answers each with up to about 160 characters. The catalogue is in AdminCatalog.swift.
public struct AdminCommand: Hashable, Sendable, Identifiable {
    /// what to send; `<…>` marks a value to fill in
    public let command: String
    public let label: String
    public let group: String
    public let about: String
    /// asks first, saying this
    public let confirm: String?
    public var id: String { command }

    public init(command: String, label: String, group: String, about: String, confirm: String? = nil) {
        self.command = command; self.label = label; self.group = group; self.about = about; self.confirm = confirm
    }

    /// It has a value to fill in before it can be sent.
    public var needsValue: Bool { command.contains("<") }

    /// The catalogue entry a typed command is (to ask first for the risky ones): exact, or by the
    /// words before its first `<value>`.
    public static func matching(_ text: String) -> AdminCommand? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return all.first { c in
            guard let r = c.command.range(of: " <") else { return c.command == t }
            return t.hasPrefix(c.command[..<r.lowerBound] + " ")
        }
    }

    public static var groups: [String] {
        var seen: [String] = []
        for c in all where !seen.contains(c.group) { seen.append(c.group) }
        return seen
    }
}

/// A setting shown as a form: read with `get <name>`, changed with `set <name> <value>`.
public struct AdminSetting: Hashable, Sendable, Identifiable {
    public let name: String
    public let label: String
    public let hint: String
    public let group: String
    public let options: [String]?
    public let confirm: String?
    public var id: String { name }

    public init(name: String, label: String, hint: String, group: String, options: [String]? = nil, confirm: String? = nil) {
        self.name = name; self.label = label; self.hint = hint; self.group = group; self.options = options; self.confirm = confirm
    }

    public var isSecret: Bool { name.contains("password") }
}

/// A line of a repeater's command line: a command sent from here, or the node's answer.
public struct ConsoleLine: Hashable, Sendable, Identifiable {
    public enum Status: String, Sendable { case sending, sent, failed, received }
    public let id: Int
    public let date: Date
    public let isCommand: Bool
    public var status: Status
    public let text: String

    public init(id: Int, date: Date = .now, isCommand: Bool, status: Status, text: String) {
        self.id = id; self.date = date; self.isCommand = isCommand; self.status = status; self.text = AdminConsole.masked(text)
    }
}

public enum AdminConsole {
    static let secretPrefixes = ["password now: ", "password ", "set guest.password ", "set prv.key ", "set bridge.secret "]   // longest match first

    /// Passwords and keys never sit in the log (the radio's web app masks the same ones).
    public static func masked(_ text: String) -> String {
        for p in secretPrefixes where text.hasPrefix(p) && text.count > p.count { return p + "\u{2022}\u{2022}\u{2022}\u{2022}" }
        return text
    }

    /// Each answer, by the command it answers: the oldest one still waiting (a node answers in order).
    public static func answers(_ lines: [ConsoleLine]) -> [Int: ConsoleLine] {
        var waiting: [ConsoleLine] = [], out: [Int: ConsoleLine] = [:]
        for l in lines {
            if l.isCommand { if l.status != .failed { waiting.append(l) } }
            else if !waiting.isEmpty { out[waiting.removeFirst().id] = l }
        }
        return out
    }

    /// The latest value of each setting: answers to `get <name>` ("> value"), and sets it accepted.
    public static func values(_ lines: [ConsoleLine]) -> [String: String] {
        let a = answers(lines)
        var v: [String: String] = [:]
        for l in lines where l.isCommand {
            guard let answer = a[l.id]?.text else { continue }
            let words = l.text.split(separator: " ", maxSplits: 2).map(String.init)
            if words.count == 2, words[0] == "get" {
                v[words[1]] = answer.hasPrefix("> ") ? String(answer.dropFirst(2)) : answer
            } else if words.count == 3, words[0] == "set", answer.uppercased().hasPrefix("OK"), !words[2].contains("\u{2022}") {
                v[words[1]] = words[2]
            }
        }
        return v
    }
}
