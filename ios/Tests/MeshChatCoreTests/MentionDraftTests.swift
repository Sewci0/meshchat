import Testing
@testable import MeshChatCore

// Writing mentions: spotting one being typed, completing it as "@Name ", sending it as "@[Name]", and
// whom to suggest.

@Suite("Mentions in the composer")
struct MentionDraftTests {
    @Test func spotsAMentionBeingTyped() {
        #expect(Mentions.typing(in: "") == nil)
        #expect(Mentions.typing(in: "hi") == nil)
        #expect(Mentions.typing(in: "@") == "")
        #expect(Mentions.typing(in: "hi @an") == "an")
        #expect(Mentions.typing(in: "line one\n@an") == "an")
        #expect(Mentions.typing(in: "@[Ania K") == "Ania K")      // the bracket form allows spaces
        #expect(Mentions.typing(in: "@[Ania] hi") == nil)         // finished
        #expect(Mentions.typing(in: "@an ") == nil)               // moved on
        #expect(Mentions.typing(in: "mail me at a@b") == nil)     // not a mention
        #expect(Mentions.typing(in: "@[Ania] and @zo") == "zo")   // the last one counts
        #expect(Mentions.typing(in: "hi @MrE", picked: ["MrE"]) == nil)   // picked already
        #expect(Mentions.typing(in: "hi @Mr", picked: ["MrE"]) == "Mr")   // cut short: being typed again
    }

    @Test func completesWithoutBrackets() {
        #expect(Mentions.complete("hi @an", with: "Ania") == "hi @Ania ")
        #expect(Mentions.complete("@[An", with: "Ania K") == "@Ania K ")
        #expect(Mentions.complete("@", with: "🇵🇱 Taxi SWD 🚖") == "@🇵🇱 Taxi SWD 🚖 ")
        #expect(Mentions.complete("hi", with: "Ania") == "hi @Ania ")   // nothing typed: added at the end
    }

    @Test func inserts() {
        #expect(Mentions.insert("Ania", into: "") == "@Ania ")
        #expect(Mentions.insert("Ania", into: "hi") == "hi @Ania ")
        #expect(Mentions.insert("Ania", into: "hi ") == "hi @Ania ")
        #expect(Mentions.insert("Ania", into: "@Ania hi") == "@Ania hi")       // already there
        #expect(Mentions.insert("Ania", into: "@[Ania] hi") == "@[Ania] hi")   // typed out in full
        #expect(Mentions.insert("Bob", into: "@[Ania] hi") == "@[Ania] hi @Bob ")
        #expect(Mentions.insert("Ann", into: "@Anna ") == "@Anna @Ann ")
    }

    @Test func findsTheMentionsToShowAndSend() {
        let draft = "@STA Brynek Cyrus hi @Ann, @Anna and @[Zosia] (mail a@b.pl)"
        let picked = ["Ann", "STA Brynek Cyrus", "Anna"]
        #expect(Mentions.spans(of: picked, in: draft).map { String(draft[$0]) }
                == ["@STA Brynek Cyrus", "@Ann", "@Anna", "@[Zosia]"])
        #expect(Mentions.wire(draft, picked: picked) == "@[STA Brynek Cyrus] hi @[Ann], @[Anna] and @[Zosia] (mail a@b.pl)")
        // only the names picked: an "@word" typed by hand stays as it is, and so does a picked name run on into a longer word
        #expect(Mentions.wire("@Ania @Bob", picked: ["Ania"]) == "@[Ania] @Bob")
        #expect(Mentions.wire("@Aniaa", picked: ["Ania"]) == "@Aniaa")
        #expect(Mentions.wire("@🇵🇱 Taxi SWD 🚖 ok", picked: ["🇵🇱 Taxi SWD 🚖"]) == "@[🇵🇱 Taxi SWD 🚖] ok")
        #expect(Mentions.wire("no mentions", picked: []) == "no mentions")
    }

    @Test func suggestsPeopleWhoWroteHereFirst() {
        let s = Mentions.suggestions(for: "a", recent: ["Zosia", "Ania", "Ania"], others: ["ania", "Adam", "Bartek"], me: "MrE")
        #expect(s == ["Ania", "Adam"])   // recent before contacts, each name once (whatever its case); one letter
                                         // matches the start of a name or word only, not Zosia's or Bartek's "a"
        #expect(Mentions.suggestions(for: "", recent: ["Zosia", "Ania"], others: ["Adam"], me: nil) == ["Zosia", "Ania", "Adam"])
        #expect(Mentions.suggestions(for: "", recent: [], others: (0..<20).map { "P\($0)" }, me: nil, limit: 6).count == 6)
    }

    @Test func matchesWordsAccentsAndEmojiNames() {
        let names = ["🇵🇱 Taxi  SWD 🚖", "Żółw", "RUSH 2112 🔩", "Uutest"]
        #expect(Mentions.suggestions(for: "swd", recent: names, others: [], me: nil) == ["🇵🇱 Taxi  SWD 🚖"])
        #expect(Mentions.suggestions(for: "zol", recent: names, others: [], me: nil) == ["Żółw"])
        #expect(Mentions.suggestions(for: "2112", recent: names, others: [], me: nil) == ["RUSH 2112 🔩"])
        // the start of a name beats the start of a word in it, which beats a match anywhere
        #expect(Mentions.suggestions(for: "un", recent: ["Bruno", "Unit 7", "Kuna"], others: [], me: nil) == ["Unit 7", "Bruno", "Kuna"])
        #expect(Mentions.suggestions(for: "ół", recent: ["Żółw"], others: [], me: nil) == ["Żółw"])
        #expect(Mentions.suggestions(for: "hill", recent: ["Chillout", "Test Hill", "Hillary"], others: [], me: nil) == ["Hillary", "Test Hill", "Chillout"])
    }

    @Test func neverSuggestsYou() {
        #expect(Mentions.suggestions(for: "", recent: ["MrE", "Ania"], others: ["mre"], me: "MrE") == ["Ania"])
    }
}
