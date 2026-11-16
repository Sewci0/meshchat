import Foundation

/// Web links in messages: finding them (to make them tappable), deciding whether a preview may be fetched
/// for one, and reading a page's title and picture out of its HTML.
public enum Links {
    /// The web links in a text, in order, with where each stands. "example.com/page" counts, as a browser
    /// would take it; email addresses and phone numbers don't.
    public static func find(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard text.contains("."), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let url = m.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(m.range, in: text) else { return nil }
            return (range, url)
        }
    }

    /// Whether a preview may be fetched for a link from the mesh, where anyone can post one: only over
    /// HTTPS, and only from a public-looking host. Not an address on your own network (a bare name, an IP
    /// address, .local and the like), so a message can't make the phone call a device at home.
    public static func fetchable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.port != nil && url.port != 443 { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty), let top = labels.last else { return false }
        if host.contains(":") || top.allSatisfy(\.isNumber) { return false }   // IPv6, IPv4
        return !["local", "lan", "home", "internal", "localhost", "localdomain", "invalid", "test", "arpa", "onion"].contains(String(top))
    }

    /// What a preview shows of a page.
    public struct Page: Equatable, Sendable {
        public var title: String?
        /// the site's own name for itself ("YouTube"), if it gives one
        public var site: String?
        public var image: URL?

        public init(title: String? = nil, site: String? = nil, image: URL? = nil) {
            self.title = title; self.site = site; self.image = image
        }
    }

    /// A page's title, site name and picture, from the tags sites publish for previews (Open Graph, then
    /// Twitter cards), falling back to its `<title>`. The picture's address is made absolute against `url`.
    public static func page(html: String, at url: URL) -> Page {
        var meta: [String: String] = [:]
        for tag in matches(#"<meta\b[^>]*>"#, in: html) {
            var attributes: [String: String] = [:]
            for a in groups(#"([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
                attributes[a[0].lowercased()] = a[1].isEmpty ? a[2] : a[1]
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(), let content = attributes["content"],
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meta[key] == nil else { continue }
            meta[key] = content
        }
        let plainTitle = groups(#"<title\b[^>]*>(.*?)</title>"#, in: html).first?.first
        let title = [meta["og:title"], meta["twitter:title"], plainTitle].compactMap { $0.map(text) }.first { !$0.isEmpty }
        let site = meta["og:site_name"].map(text).flatMap { $0.isEmpty ? nil : $0 }
        let image = [meta["og:image:secure_url"], meta["og:image"], meta["twitter:image"], meta["twitter:image:src"]]
            .compactMap { $0.map(text) }.first { !$0.isEmpty }
            .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return Page(title: title.map { String($0.prefix(200)) }, site: site.map { String($0.prefix(60)) }, image: image)
    }

    /// Text out of HTML: entities decoded, runs of white space made one space.
    static func text(_ html: String) -> String {
        var s = html
        if s.contains("&") {
            for g in groups(#"&#(x?)([0-9a-fA-F]+);"#, in: s) {
                guard let code = UInt32(g[1], radix: g[0].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) else { continue }
                s = s.replacingOccurrences(of: "&#\(g[0])\(g[1]);", with: String(Character(scalar)))
            }
            for (entity, character) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&ndash;", "–"),
                                        ("&mdash;", "—"), ("&hellip;", "…"), ("&amp;", "&")] {
                s = s.replacingOccurrences(of: entity, with: character)
            }
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// Each match's capture groups (an unmatched group as "").
    private static func groups(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }
}
