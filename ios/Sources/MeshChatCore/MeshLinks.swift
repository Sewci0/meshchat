import Foundation
import MeshCoreKit

/// meshcore:// links, as the MeshCore apps put them in QR codes:
///   meshcore://contact/add?name=Example&public_key=<64 hex>&type=1   (1 companion, 2 repeater, 3 room, 4 sensor)
///   meshcore://channel/add?name=Public&secret=<32 hex>
/// and this app's own, for a network's radio settings:
///   meshcore://network/add?name=…&freq=869.618&bw=62.5&sf=6&cr=8[&tx=22][&hash=2]
public enum MeshLink: Hashable, Sendable {
    case contact(name: String, key: PublicKey, type: NodeType)
    case channel(name: String, secret: Data)
    case network(RadioProfile)

    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), c.scheme?.lowercased() == "meshcore", c.path.lowercased() == "/add" else { return nil }
        // URLComponents leaves "+" alone; the apps write spaces as "+"
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, ($0.value ?? "").replacingOccurrences(of: "+", with: " ")) }, uniquingKeysWith: { a, _ in a })
        let name = MeshLink.fitName(q["name"] ?? "")
        switch c.host?.lowercased() {
        case "contact":
            guard let key = PublicKey(hex: (q["public_key"] ?? "").lowercased()), let raw = UInt8(q["type"] ?? "1"),
                  (1...4).contains(raw), let type = NodeType(rawValue: raw) else { return nil }
            self = .contact(name: name.isEmpty ? String(key.hex.prefix(8)) : name, key: key, type: type)
        case "channel":
            guard !name.isEmpty, let s = q["secret"], s.count == 32, let secret = Data(hex: s) else { return nil }
            self = .channel(name: name, secret: secret)
        case "network":
            guard let p = RadioProfile.fromLink(q) else { return nil }
            self = .network(p)
        default:
            return nil
        }
    }

    /// The link the MeshCore apps scan to add a contact.
    public static func contactLink(name: String, key: PublicKey, type: NodeType = .companion) -> String {
        var c = URLComponents()
        c.scheme = "meshcore"; c.host = "contact"; c.path = "/add"
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "public_key", value: key.hex),
                        URLQueryItem(name: "type", value: String(type.rawValue))]
        return c.string ?? ""
    }

    /// The radio keeps names in 32 bytes (31 and a terminator): cut on a whole character.
    public static func fitName(_ name: String, bytes: Int = 31) -> String {
        name.trimmingCharacters(in: .whitespaces).utf8Prefix(maxBytes: bytes)
    }
}

/// How your recent DMs to one contact went: for route details.
public struct DeliveryStats: Hashable, Sendable {
    public enum Outcome: String, Sendable { case onRoute, byFlood, delivered, noReceipt, failed, pending }

    public let sent: Int, delivered: Int, firstTry: Int, onRoute: Int, byFlood: Int, noReceipt: Int, failed: Int
    public let medianRoundTripOnRoute: Int?, medianRoundTripByFlood: Int?
    /// of the last five, how many got no receipt (a stale route shows as a run of these)
    public let recentMisses: Int
    public let recent: [(Message, Outcome)]

    public static func outcome(_ m: Message) -> Outcome {
        switch m.status {
        case .sending, .sent: .pending
        case .noAck: .noReceipt
        case .failed: .failed
        case .delivered:
            if let t = m.ackTry, let tries = m.triesFlood, tries.indices.contains(t - 1) { tries[t - 1] ? .byFlood : .onRoute } else { .delivered }
        default: .pending
        }
    }

    public init(_ messages: [Message]) {
        let out = messages.filter { $0.direction == .outgoing }.suffix(40)
        let done = out.map { ($0, Self.outcome($0)) }.filter { $0.1 != .pending }
        func median(_ o: Outcome) -> Int? {
            let v = done.filter { $0.1 == o }.compactMap { $0.0.roundTripMs }.sorted()
            return v.isEmpty ? nil : v[v.count / 2]
        }
        sent = done.count
        delivered = done.filter { [.onRoute, .byFlood, .delivered].contains($0.1) }.count
        firstTry = done.filter { $0.0.ackTry == 1 }.count
        onRoute = done.filter { $0.1 == .onRoute }.count
        byFlood = done.filter { $0.1 == .byFlood }.count
        noReceipt = done.filter { $0.1 == .noReceipt }.count
        failed = done.filter { $0.1 == .failed }.count
        medianRoundTripOnRoute = median(.onRoute)
        medianRoundTripByFlood = median(.byFlood)
        recentMisses = done.suffix(5).filter { $0.1 == .noReceipt }.count
        recent = out.suffix(8).reversed().map { ($0, Self.outcome($0)) }
    }

    public static func == (a: DeliveryStats, b: DeliveryStats) -> Bool { a.sent == b.sent && a.delivered == b.delivered && a.recentMisses == b.recentMisses }
    public func hash(into h: inout Hasher) { h.combine(sent); h.combine(delivered) }
}

extension RadioSettings {
    /// LoRa bandwidths the SX126x and SX127x support, in kHz.
    public static let bandwidths: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

    /// "869.618 MHz · 62.5 kHz · SF6 · CR8"
    public var summary: String {
        String(format: "%.3f MHz · %@ kHz · SF%d · CR%d", frequencyMHz, bandwidthKHz.formatted(), spreadingFactor, codingRate)
    }

    /// Why the radio would refuse these (its own checks: 150–2500 MHz, 7–500 kHz, SF5–12, CR5–8).
    public var problem: String? {
        if !(150...2500).contains(frequencyMHz) { return String(localized: "The frequency must be between 150 and 2500 MHz.") }
        if !(7...500).contains(bandwidthKHz) { return String(localized: "The bandwidth must be between 7 and 500 kHz.") }
        if !(5...12).contains(spreadingFactor) { return String(localized: "The spreading factor must be 5 to 12.") }
        if !(5...8).contains(codingRate) { return String(localized: "The coding rate must be 5 to 8.") }
        return nil
    }

    public var isValid: Bool { problem == nil }
}
