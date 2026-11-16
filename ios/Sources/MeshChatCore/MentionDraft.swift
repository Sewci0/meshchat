import Foundation

/// Writing mentions: MeshCore apps send them as "@[Name]", which is awkward to type on a phone (the
/// brackets, and names with emoji or spaces). Type "@" and a few letters, pick the person, and the draft
/// gets "@Name ", shown as in the bubbles; the names picked are kept alongside the draft, and `wire`
/// puts the brackets back when it's sent.
extension Mentions {
    /// The mention being typed at the end of a draft: "hi @an" gives "an", "@[Ania K" gives "Ania K", a
    /// lone "@" gives "". Nil when there's none (no "@", a finished "@[Name]" or picked "@Name", a space
    /// after the word, or an "@" inside a word, as in an email address).
    public static func typing(in draft: String, picked: [String] = []) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        if spans(of: picked, in: draft).contains(where: { $0.lowerBound == at }) { return nil }
        var rest = draft[draft.index(after: at)...]
        if rest.first == "[" {
            rest = rest.dropFirst()
            return rest.contains("]") ? nil : String(rest)
        }
        return rest.contains(where: { $0.isWhitespace || $0 == "]" }) ? nil : String(rest)
    }

    /// The draft with the mention being typed replaced by "@name " (or, with none being typed, the
    /// mention added at the end).
    public static func complete(_ draft: String, with name: String) -> String {
        guard typing(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return insert(name, into: draft) }
        return String(draft[..<at]) + "@\(name) "
    }

    /// "@name " added at the end of the draft, unless it's already there.
    public static func insert(_ name: String, into draft: String) -> String {
        let tag = "@" + name
        if spans(of: [name], in: draft).contains(where: { draft[$0] == tag || draft[$0] == "@[\(name)]" }) { return draft }
        if draft.isEmpty { return tag + " " }
        return draft + (draft.last?.isWhitespace == true ? "" : " ") + tag + " "
    }

    /// Where the mentions stand in a draft: each picked name written "@name", and any "@[name]" typed
    /// out in full. An "@" inside a word (an email address) doesn't start one, and a name followed by a
    /// letter or digit doesn't count ("@Ann" isn't in "@Anna"); of two picked names, the longer wins.
    public static func spans(of picked: [String], in draft: String) -> [Range<String.Index>] {
        let names = picked.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var out: [Range<String.Index>] = []
        var i = draft.startIndex
        while let at = draft[i...].firstIndex(of: "@") {
            let after = draft.index(after: at)
            i = after
            if at > draft.startIndex, draft[draft.index(before: at)].isLetter || draft[draft.index(before: at)].isNumber { continue }
            let rest = draft[after...]
            if rest.first == "[", let close = rest.firstIndex(of: "]"), !rest[..<close].contains("\n") {
                let end = draft.index(after: close)
                out.append(at..<end); i = end
                continue
            }
            for name in names where rest.hasPrefix(name) {
                let end = draft.index(at, offsetBy: name.count + 1)
                if end < draft.endIndex, draft[end].isLetter || draft[end].isNumber { continue }
                out.append(at..<end); i = end
                break
            }
        }
        return out
    }

    /// The draft as it's sent: each picked "@name" as MeshCore's "@[name]".
    public static func wire(_ draft: String, picked: [String]) -> String {
        var out = "", from = draft.startIndex
        for span in spans(of: picked, in: draft) {
            out += draft[from..<span.lowerBound]
            let tag = draft[span]
            out += tag.hasPrefix("@[") ? String(tag) : "@[" + tag.dropFirst() + "]"
            from = span.upperBound
        }
        return out + draft[from...]
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
