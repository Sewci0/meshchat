import Foundation
import MeshCoreKit

/// A saved network: the LoRa settings that put a radio on one mesh (radios hear only others set the
/// same), under a name you choose, and if you like the transmit power and path hash size to use there.
/// Kept on this iPhone, editable, and shared as a meshcore://network/add link.
public struct RadioProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var radio: RadioSettings
    public var notes: String?
    public var link: URL?
    /// nil: leave the radio's as it is
    public var txPower: Int?
    /// 0, 1 or 2 (path hashes of 1, 2 or 3 bytes); nil: leave the radio's
    public var pathHashMode: Int?
    /// the suggested network it was added from
    public var seedID: String?

    public static let maxName = 40

    public init(id: UUID = UUID(), name: String, radio: RadioSettings, notes: String? = nil, link: URL? = nil,
                txPower: Int? = nil, pathHashMode: Int? = nil, seedID: String? = nil) {
        self.id = id; self.name = name; self.radio = radio; self.notes = notes; self.link = link
        self.txPower = txPower; self.pathHashMode = pathHashMode; self.seedID = seedID
    }

    /// The same network: frequency within 0.5 kHz, bandwidth within 0.05 kHz, the same spreading factor
    /// and coding rate (floats from the radio don't come back exactly as typed).
    public static func sameNetwork(_ a: RadioSettings, _ b: RadioSettings) -> Bool {
        abs(a.frequencyMHz - b.frequencyMHz) < 0.0005 && abs(a.bandwidthKHz - b.bandwidthKHz) < 0.05
            && a.spreadingFactor == b.spreadingFactor && a.codingRate == b.codingRate
    }

    /// Networks to start from. Added to your profiles they're yours: rename, change or delete them.
    public static let suggested: [RadioProfile] = [
        RadioProfile(id: UUID(uuidString: "6F0B1D2E-0000-4000-8000-000000000001")!, name: "MeshCore Południe",
                     radio: RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 6, codingRate: 8),
                     notes: String(localized: "Southern Poland: Silesia, Częstochowa and the Jura. Fast (SF6), with dense repeaters."),
                     link: URL(string: "https://meshcoresouth.pl/"), seedID: "pl-south"),
        RadioProfile(id: UUID(uuidString: "6F0B1D2E-0000-4000-8000-000000000002")!, name: "MeshCore Polska",
                     radio: RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8),
                     notes: String(localized: "The national standard (EU/UK Narrow), used across most of Poland. Slower (SF8), longer range per hop."),
                     link: URL(string: "https://meshcorepolska.org/"), seedID: "pl-national"),
    ]

    /// meshcore://network/add?name=…&freq=869.618&bw=62.5&sf=6&cr=8[&tx=22][&hash=2]
    public var shareLink: String {
        var c = URLComponents()
        c.scheme = "meshcore"; c.host = "network"; c.path = "/add"
        var q = [URLQueryItem(name: "name", value: name),
                 URLQueryItem(name: "freq", value: Self.number(radio.frequencyMHz, decimals: 3)),
                 URLQueryItem(name: "bw", value: Self.number(radio.bandwidthKHz, decimals: 2)),
                 URLQueryItem(name: "sf", value: String(radio.spreadingFactor)),
                 URLQueryItem(name: "cr", value: String(radio.codingRate))]
        if let txPower { q.append(URLQueryItem(name: "tx", value: String(txPower))) }
        if let pathHashMode { q.append(URLQueryItem(name: "hash", value: String(pathHashMode + 1))) }
        c.queryItems = q
        return c.string ?? ""
    }

    /// A profile from a network link's values (nil if anything is missing or out of range).
    static func fromLink(_ q: [String: String]) -> RadioProfile? {
        func number(_ k: String) -> Double? { q[k].flatMap(Double.init) }   // "869,618" is refused
        guard let name = q["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let f = number("freq"), let bw = number("bw"), let sf = q["sf"].flatMap(Int.init), let cr = q["cr"].flatMap(Int.init)
        else { return nil }
        let radio = RadioSettings(frequencyMHz: f, bandwidthKHz: bw, spreadingFactor: sf, codingRate: cr)
        guard radio.isValid else { return nil }
        let tx = q["tx"].flatMap(Int.init).flatMap { (-9...30).contains($0) ? $0 : nil }
        let hash = q["hash"].flatMap(Int.init).flatMap { (1...3).contains($0) ? $0 - 1 : nil }
        return RadioProfile(name: String(name.prefix(maxName)), radio: radio, txPower: tx, pathHashMode: hash)
    }

    /// "869.618", "62.5": no trailing zeros, always a point
    public static func number(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Your saved networks, in your order: kept on this iPhone (the app stores it as JSON).
public struct RadioProfileStore: Codable, Hashable, Sendable {
    public private(set) var profiles: [RadioProfile]
    /// the suggested networks were put in once; deleting one doesn't bring it back
    public private(set) var seeded: Bool

    public init(profiles: [RadioProfile] = [], seeded: Bool = false) {
        self.profiles = profiles
        self.seeded = seeded
    }

    /// The first profile (in your order) for the network these settings are on.
    public func match(_ r: RadioSettings) -> RadioProfile? {
        profiles.first { RadioProfile.sameNetwork($0.radio, r) }
    }

    /// The first time: the suggested networks, so nothing the app used to list disappears.
    public mutating func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        for s in RadioProfile.suggested where !profiles.contains(where: { $0.seedID == s.seedID }) { profiles.append(s) }
    }

    /// Suggested networks you haven't got (any more), to add again.
    public var suggestions: [RadioProfile] {
        RadioProfile.suggested.filter { s in !profiles.contains { $0.seedID == s.seedID } }
    }

    /// Adds it with a name no other profile has ("Home" → "Home 2"); returns what was added.
    @discardableResult
    public mutating func add(_ p: RadioProfile) -> RadioProfile {
        var p = p
        if profiles.contains(where: { $0.id == p.id }) { p.id = UUID() }
        p.name = uniqueName(p.name)
        profiles.append(p)
        return p
    }

    /// Saves changes to one already here (its name kept unique).
    public mutating func update(_ p: RadioProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        var p = p
        p.name = uniqueName(p.name, excluding: p.id)
        profiles[i] = p
    }

    public mutating func remove(id: UUID) { profiles.removeAll { $0.id == id } }

    /// A copy, right after the original, called "… copy".
    @discardableResult
    public mutating func duplicate(id: UUID) -> RadioProfile? {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = profiles[i]
        copy.id = UUID()
        copy.seedID = nil
        copy.name = uniqueName(String(localized: "\(String(copy.name.prefix(RadioProfile.maxName - 5))) copy", comment: "A duplicated network's name: \"Home copy\""))
        profiles.insert(copy, at: i + 1)
        return copy
    }

    /// Moves profiles as a list's drag does (offsets before the move, destination before removal).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { profiles[$0] }
        let before = source.filter { $0 < destination }.count
        profiles = profiles.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        profiles.insert(contentsOf: moving, at: min(profiles.count, destination - before))
    }

    /// `name`, or with " 2", " 3"… added if another profile has it already (case ignored).
    public func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        let base = String(name.trimmingCharacters(in: .whitespaces).prefix(RadioProfile.maxName))
        let fallback = base.isEmpty ? String(localized: "Network", comment: "The name of a saved network left without one") : base
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(fallback.lowercased()) else { return fallback }
        var n = 2
        while taken.contains("\(fallback) \(n)".lowercased()) { n += 1 }
        return "\(fallback) \(n)"
    }
}
