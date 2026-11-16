import Foundation
import Testing
@testable import MeshChatCore

// Links in messages: which text counts as one, which may be fetched for a preview, and reading a page.

@Suite("People heard lately")
struct PeopleHeardTests {
    @Test func countsEachPersonOnce() {
        // Ania wrote twice and advertised (her name differently cased there); you don't count
        #expect(PeopleHeard.count(writers: ["Ania", "Zosia", "Ania", "MrE"], advertisers: ["ania ", "Bartek"], me: "MrE") == 3)
        #expect(PeopleHeard.count(writers: [], advertisers: [], me: "MrE") == 0)
        #expect(PeopleHeard.count(writers: ["", "MrE"], advertisers: [], me: "mre") == 0)
    }

    @Test func aMessageDeliveredLateIsNotSomeoneHeardNow() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        #expect(PeopleHeard.writtenLately(senderTimestamp: 1_794_000_000 - 1200, now: now))      // 20 minutes ago
        #expect(!PeopleHeard.writtenLately(senderTimestamp: 1_794_000_000 - 5 * 3600, now: now)) // kept by the radio for 5 hours
        #expect(PeopleHeard.writtenLately(senderTimestamp: 1_000, now: now))                     // a clock never set: arrival decides
        #expect(PeopleHeard.writtenLately(senderTimestamp: nil, now: now))
    }
}

@Suite("Links in messages")
struct LinksTests {
    @Test func findsWebLinks() {
        let text = "mapa: https://map.meshcore.io/#7/52.1/19.4 albo meshcore.co.uk, pisz na a@b.pl"
        let found = Links.find(in: text)
        #expect(found.first?.url.absoluteString == "https://map.meshcore.io/#7/52.1/19.4")
        #expect(found.map(\.url.host) == ["map.meshcore.io", "meshcore.co.uk"])   // a bare name gets a scheme
        #expect(found.map { String(text[$0.range]) } == ["https://map.meshcore.io/#7/52.1/19.4", "meshcore.co.uk"])
        #expect(Links.find(in: "no links here").isEmpty)
        #expect(Links.find(in: "SNR 7.5 dB, 3.95 V").isEmpty)
    }

    @Test func previewsOnlyFromPublicHttpsSites() {
        #expect(Links.fetchable(URL(string: "https://example.com/page?x=1")!))
        #expect(!Links.fetchable(URL(string: "http://example.com")!))               // not encrypted
        #expect(!Links.fetchable(URL(string: "https://192.168.1.1/admin")!))        // an address on your network
        #expect(!Links.fetchable(URL(string: "https://[fe80::1]/")!))
        #expect(!Links.fetchable(URL(string: "https://meshcore.local/")!))
        #expect(!Links.fetchable(URL(string: "https://router/")!))
        #expect(!Links.fetchable(URL(string: "https://example.com:8443/")!))
        #expect(!Links.fetchable(URL(string: "https://user:pass@example.com/")!))
    }

    @Test func readsAPagesTitleAndPicture() {
        let html = """
        <html><head><title>Plain &amp; simple</title>
        <meta property="og:title" content="MeshCore &#8211; off-grid &quot;mesh&quot;">
        <meta content='MeshCore' property='og:site_name'>
        <meta name="twitter:image" content="/img/card.png">
        </head><body><meta property="og:title" content="later ones don't count"></body></html>
        """
        let page = Links.page(html: html, at: URL(string: "https://meshcore.co.uk/docs/start")!)
        #expect(page == Links.Page(title: "MeshCore – off-grid \"mesh\"", site: "MeshCore", image: URL(string: "https://meshcore.co.uk/img/card.png")))

        // no preview tags: the page's own title, and no picture
        let plain = Links.page(html: "<TITLE>\n  Zwykła   strona\n</TITLE>", at: URL(string: "https://example.pl")!)
        #expect(plain == Links.Page(title: "Zwykła strona"))
        #expect(Links.page(html: "not html", at: URL(string: "https://example.pl")!) == Links.Page())
    }
}
