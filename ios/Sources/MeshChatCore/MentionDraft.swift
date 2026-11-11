import Foundation

/// Writing mentions: MeshCore apps write them "@[Name]", which is awkward to type on a phone (the
/// brackets, and names with emoji or spaces). Type "@" and a few letters, pick the person, and the
/// draft gets the full "@[Name] ".
extension Mentions {
    /// The mention being typed at the end of a draft: "hi @an" gives "an", "@[Ania K" gives "Ania K", a
    /// lone "@" gives "". Nil when there's none (no "@", a finished "@[Name]", a space after the word,
    /// or an "@" inside a word, as in an email address).
    public static func typing(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        var rest = draft[draft.index(after: at)...]
        if rest.first == "[" {
            rest = rest.dropFirst()
            return rest.contains("]") ? nil : String(rest)
        }
        return rest.contains(where: { $0.isWhitespace || $0 == "]" }) ? nil : String(rest)
    }

    /// The draft with the mention being typed replaced by "@[name] " (or, with none being typed, the
    /// mention added at the end).
    public static func complete(_ draft: String, with name: String) -> String {
        guard typing(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return insert(name, into: draft) }
        return String(draft[..<at]) + "@[\(name)] "
    }

    /// "@[name] " added at the end of the draft, unless it's already there.
    public static func insert(_ name: String, into draft: String) -> String {
        let tag = "@[\(name)]"
        if draft.contains(tag) { return draft }
        if draft.isEmpty { return tag + " " }
        return draft + (draft.last?.isWhitespace == true ? "" : " ") + tag + " "
    }

    /// The draft ready for a name: an "@" at the end, after a space if it needs one.
    public static func start(_ draft: String) -> String {
        if typing(in: draft) != nil { return draft }
        return draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "@" : " @")
    }

    /// Whom to suggest for `query`: people who wrote here lately first (newest first), then `others`
    /// (contacts) by name. A name matches from its start, then from the start of any word in it, then
    /// (for two letters or more) anywhere, ignoring case and accents ("zol" finds "Żółw", "swd" finds
    /// "🇵🇱 Taxi SWD 🚖"). Never you, never a name twice.
    public static func suggestions(for query: String, recent: [String], others: [String], me: String?, limit: Int = 6) -> [String] {
        func key(_ s: String) -> String {
            // letters that aren't a base letter plus an accent, so folding leaves them as they are
            normalized(s).folding(options: [.diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "ø", with: "o")
                .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "ß", with: "ss")
        }
        let q = key(query)
        let mine = me.map(key)
        var seen = Set<String>()
        var pool: [(name: String, order: Int)] = []
        for (i, n) in (recent + others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }).enumerated() {
            let k = key(n)
            guard !k.isEmpty, k != mine, seen.insert(k).inserted else { continue }
            pool.append((n, i))
        }
        func rank(_ name: String) -> Int? {
            let k = key(name)
            if q.isEmpty || k.hasPrefix(q) { return 0 }
            if k.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 1 }
            return q.count > 1 && k.contains(q) ? 2 : nil
        }
        return pool.compactMap { p in rank(p.name).map { (name: p.name, rank: $0, order: p.order) } }
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(limit)
            .map(\.name)
    }
}
