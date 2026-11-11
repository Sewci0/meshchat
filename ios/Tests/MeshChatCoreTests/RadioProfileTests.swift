import Foundation
import Testing
@testable import MeshChatCore
@testable import MeshCoreKit

// Saved networks: matching what the radio is on, the store's rules, and sharing them as links.

private let south = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)

@Suite("Radio profiles")
struct RadioProfileTests {
    @Test func matchesDespiteFloatRounding() {
        var store = RadioProfileStore()
        store.add(RadioProfile(name: "Home", radio: south))
        #expect(store.match(RadioSettings(frequencyMHz: 869.6182, bandwidthKHz: 62.49, spreadingFactor: 6, codingRate: 8))?.name == "Home")
        #expect(store.match(RadioSettings(frequencyMHz: 869.62, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8)) == nil)
        #expect(store.match(RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 8)) == nil)
    }

    @Test func seedsOnceAndDeletedSuggestionsStayGone() {
        var store = RadioProfileStore()
        store.seedIfNeeded()
        #expect(store.profiles.map(\.name) == ["MeshCore Południe", "MeshCore Polska"])
        #expect(store.suggestions.isEmpty)
        store.remove(id: store.profiles[0].id)
        store.seedIfNeeded()
        #expect(store.profiles.map(\.name) == ["MeshCore Polska"])
        #expect(store.suggestions.map(\.name) == ["MeshCore Południe"])   // can be added again by hand
        // it survives a round trip through storage
        let back = try? JSONDecoder().decode(RadioProfileStore.self, from: JSONEncoder().encode(store))
        #expect(back == store)
    }

    @Test func namesStayUnique() {
        var store = RadioProfileStore()
        store.add(RadioProfile(name: "Home", radio: south))
        #expect(store.add(RadioProfile(name: "home", radio: south)).name == "home 2")
        #expect(store.add(RadioProfile(name: "  ", radio: south)).name == "Network")
        let copy = store.duplicate(id: store.profiles[0].id)
        #expect(copy?.name == "Home copy")
        #expect(store.profiles[1].id == copy?.id)   // right after the original
        var renamed = store.profiles[0]
        renamed.name = "Home"
        store.update(renamed)   // its own name isn't a clash
        #expect(store.profiles[0].name == "Home")
    }

    @Test func movesAsAListDoes() {
        var store = RadioProfileStore()
        for n in ["A", "B", "C", "D"] { store.add(RadioProfile(name: n, radio: south)) }
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.profiles.map(\.name) == ["B", "C", "A", "D"])
        store.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        #expect(store.profiles.map(\.name) == ["A", "D", "B", "C"])
    }

    @Test func sharedAsALinkAndBack() throws {
        let p = RadioProfile(name: "MeshCore Południe", radio: south, txPower: 22, pathHashMode: 1)
        #expect(p.shareLink.hasPrefix("meshcore://network/add?name=MeshCore%20Po"))
        #expect(p.shareLink.contains("freq=869.618") && p.shareLink.contains("bw=62.5") && p.shareLink.contains("tx=22") && p.shareLink.contains("hash=2"))
        guard case .network(let back)? = MeshLink(p.shareLink) else { Issue.record("not a network link"); return }
        #expect(back.name == "MeshCore Południe")
        #expect(RadioProfile.sameNetwork(back.radio, south))
        #expect(back.txPower == 22 && back.pathHashMode == 1)
    }

    @Test func badNetworkLinksAreRefused() {
        #expect(MeshLink("meshcore://network/add?name=X&freq=869,618&bw=62.5&sf=6&cr=8") == nil)   // a comma
        #expect(MeshLink("meshcore://network/add?name=X&freq=50&bw=62.5&sf=6&cr=8") == nil)        // out of range
        #expect(MeshLink("meshcore://network/add?name=X&freq=869.618&bw=62.5&sf=13&cr=8") == nil)
        #expect(MeshLink("meshcore://network/add?freq=869.618&bw=62.5&sf=6&cr=8") == nil)          // no name
        guard case .network(let p)? = MeshLink("meshcore://network/add?name=Test&freq=869.618&bw=62.5&sf=6&cr=8&tx=99&hash=5") else {
            Issue.record("not a network link"); return
        }
        #expect(p.txPower == nil && p.pathHashMode == nil)   // nonsense extras dropped, the network kept
    }
}
