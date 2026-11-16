import CryptoKit
import MeshChatCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where a link's preview loads by itself. Fetching one contacts the link's website, which sees the
/// phone's internet address, and on the mesh anyone can post a link: so by default only in direct
/// messages, and with a tap elsewhere.
public enum LinkPreviewMode: String, CaseIterable, Sendable {
    case everywhere, direct, tapped

    public var label: String {
        switch self {
        case .everywhere: String(localized: "Everywhere")
        case .direct: String(localized: "Direct messages only")
        case .tapped: String(localized: "When tapped")
        }
    }
}

#if os(iOS)
/// Link previews: fetched once, kept (title, site, a small picture) in the caches folder, and shared by
/// every message with that link.
///
/// The fetch is the app's own and small: one request for the page (no cookies, nothing stored by the
/// system, no scripts run, at most 400 KB read), one for its picture; only over HTTPS and only from
/// public hosts (`Links.fetchable`), redirects included.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()

    struct Preview {
        var title: String?
        var site: String
        var image: UIImage?
    }

    enum State {
        case loading
        case loaded(Preview)
        /// asked, and there was nothing to show (not fetched again until the app restarts)
        case failed
    }

    private var states: [URL: State] = [:]
    /// previews kept from earlier runs, read as they're asked for (nil inside: looked for, none kept)
    @ObservationIgnored private var kept: [URL: State?] = [:]
    @ObservationIgnored private let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let f = caches.appendingPathComponent("LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    /// What's known of a link's preview: nil when it hasn't been asked for (here or on an earlier run).
    func state(for url: URL) -> State? {
        if let s = states[url] { return s }
        if let looked = kept[url] { return looked }
        var found: State?
        if let file = file(url), let data = try? Data(contentsOf: file.appendingPathExtension("json")),
           let k = try? JSONDecoder().decode(Kept.self, from: data) {
            let image = (try? Data(contentsOf: file.appendingPathExtension("jpg"))).flatMap(UIImage.init(data:))
            found = .loaded(Preview(title: k.title, site: k.site, image: image))
        }
        kept[url] = .some(found)
        return found
    }

    func isLoaded(_ url: URL) -> Bool {
        if case .loaded = state(for: url) { true } else { false }
    }

    func load(_ url: URL) {
        guard state(for: url) == nil, Links.fetchable(url) else { return }
        states[url] = .loading
        Task {
            guard let fetched = await Self.fetch(url) else { states[url] = .failed; return }
            let site = fetched.page.site ?? Self.host(url)
            states[url] = .loaded(Preview(title: fetched.page.title, site: site, image: fetched.image.flatMap(UIImage.init(data:))))
            if let file = file(url) {
                try? JSONEncoder().encode(Kept(title: fetched.page.title, site: site)).write(to: file.appendingPathExtension("json"))
                if let image = fetched.image { try? image.write(to: file.appendingPathExtension("jpg")) }
            }
        }
    }

    /// "example.com", without "www.".
    static func host(_ url: URL) -> String {
        let h = url.host ?? url.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private struct Kept: Codable {
        var title: String?
        var site: String
    }

    private func file(_ url: URL) -> URL? {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name)
    }

    // MARK: fetching

    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 20
        // what link-preview fetchers send, and sites answer with their preview tags
        c.httpAdditionalHeaders = ["User-Agent": "facebookexternalhit/1.1 Facebot Twitterbot/1.0", "Accept": "text/html,image/*;q=0.9,*/*;q=0.5"]
        return URLSession(configuration: c, delegate: Redirects(), delegateQueue: nil)
    }()

    /// A redirect is followed only to somewhere a preview may be fetched from.
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url.map(Links.fetchable) == true ? request : nil
        }
    }

    /// The page's title, site and picture (as a small JPEG), or nil when there's nothing worth showing.
    private nonisolated static func fetch(_ url: URL) async -> (page: Links.Page, image: Data?)? {
        guard let (data, response) = await get(url, limit: 400_000, untilHeadEnds: true) else { return nil }
        let type = response.mimeType?.lowercased() ?? ""
        if type.hasPrefix("image/") {
            // a link straight to a picture
            guard let all = await get(url, limit: 6_000_000)?.data, let small = thumbnail(all) else { return nil }
            return (Links.Page(), small)
        }
        guard type.contains("html") else { return nil }
        let page = Links.page(html: text(data, response), at: url)
        var image: Data?
        if let i = page.image, Links.fetchable(i), let raw = await get(i, limit: 6_000_000)?.data { image = thumbnail(raw) }
        return page.title == nil && image == nil ? nil : (page, image)
    }

    /// Up to `limit` bytes of what's at `url` (a page is read only as far as the end of its head, where the
    /// preview tags are).
    private nonisolated static func get(_ url: URL, limit: Int, untilHeadEnds: Bool = false) async -> (data: Data, response: HTTPURLResponse)? {
        guard Links.fetchable(url), let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        var data = Data()
        let end = Array("</head>".utf8)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
                if untilHeadEnds, byte == UInt8(ascii: ">"), data.count >= end.count,
                   data.suffix(end.count).elementsEqual(end, by: { $0 | 0x20 == $1 }) { break }
            }
        } catch { if data.isEmpty { return nil } }
        return (data, http)
    }

    /// The page as text: in the encoding it declares (many Polish and Czech sites aren't UTF-8), else UTF-8.
    private nonisolated static func text(_ data: Data, _ response: HTTPURLResponse) -> String {
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// At most 720 pixels wide, as a JPEG.
    private nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 720 / max(image.size.width * image.scale, 1))
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// A link's preview, as the top of its message's bubble (as in Messages): the page's picture across the
/// bubble, then its title and the site on a shaded strip. Tap it to open the link. Where previews don't
/// load by themselves (`auto`), the strip has just the site's name and loads the preview when tapped.
/// The bubble gives it its width, colour and rounded corners.
struct LinkPreviewCard: View {
    let url: URL
    /// load without being asked
    let auto: Bool
    /// in your own (tinted) bubble
    var outgoing = false
    @Environment(\.openURL) private var openURL
    private var previews: LinkPreviews { .shared }

    private var quiet: Color { outgoing ? .white.opacity(0.75) : .secondary }
    /// the strip, a shade off the bubble
    private var shade: Color { outgoing ? .white.opacity(0.16) : .primary.opacity(0.06) }

    var body: some View {
        let state = previews.state(for: url)
        Group {
            switch state {
            case .loaded(let p):
                Button { openURL(url) } label: { card(p) }
                    .accessibilityLabel(Text(verbatim: [p.title, p.site].compactMap { $0 }.joined(separator: ", ")))
                    .accessibilityHint("Opens the link")
            case .loading:
                strip(loading: true)
            case .failed:
                Button { openURL(url) } label: { strip(loading: false, hint: false) }
                    .accessibilityHint("Opens the link")
            case nil:
                Button { previews.load(url) } label: { strip(loading: false, hint: !auto) }
            }
        }
        .buttonStyle(.plain)
        .task(id: "\(auto) \(url.absoluteString)") { if auto { previews.load(url) } }
    }

    private func card(_ p: LinkPreviews.Preview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = p.image {
                // a wide strip for the usual 1.91:1 card picture; a square or portrait one is cropped to a
                // little wider than tall, so one link doesn't fill the screen
                let ratio = min(max(image.size.width / max(image.size.height, 1), 1.3), 2.2)
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = p.title { Text(title).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading) }
                // (a home page's title is often just the site's name: the address then)
                Text(p.title == p.site ? LinkPreviews.host(url) : p.site).font(.caption).foregroundStyle(quiet).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shade)
        }
        .contentShape(.rect)
    }

    /// Before there's a preview: the site, and what a tap does.
    private func strip(loading: Bool, hint: Bool = false) -> some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small).tint(outgoing ? .white : nil) } else { Image(systemName: "link").foregroundStyle(quiet) }
            VStack(alignment: .leading, spacing: 1) {
                Text(LinkPreviews.host(url)).font(.footnote.weight(.semibold)).lineLimit(1)
                if hint { Text("Tap to load preview").font(.caption).foregroundStyle(quiet) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shade)
        .contentShape(.rect)
    }
}
#endif
