import Foundation
import MeshCoreKit

/// Which mesh something was heard on: the radio's frequency, bandwidth and spreading factor, kept with
/// messages, packets and heard nodes as "869.618/62.5/6" (radios hear only others set the same). The
/// coding rate isn't part of it: radios with different ones still hear each other's packets.
public struct NetworkKey: Hashable, Sendable {
    public let frequencyMHz: Double
    public let bandwidthKHz: Double
    public let spreadingFactor: Int

    public init(_ r: RadioSettings) {
        frequencyMHz = r.frequencyMHz; bandwidthKHz = r.bandwidthKHz; spreadingFactor = r.spreadingFactor
    }

    /// From a kept key ("869.618/62.5/6"); nil for anything else.
    public init?(_ key: String) {
        let parts = key.split(separator: "/")
        guard parts.count == 3, let f = Double(parts[0]), let b = Double(parts[1]), let sf = Int(parts[2]) else { return nil }
        frequencyMHz = f; bandwidthKHz = b; spreadingFactor = sf
    }

    /// As kept: "869.618/62.5/6".
    public var key: String { String(format: "%.3f/%g/%d", frequencyMHz, bandwidthKHz, spreadingFactor) }

    /// For a network with no saved name: "869.618 MHz · 62.5 kHz · SF6".
    public var label: String { String(format: "%.3f MHz · %g kHz · SF%d", frequencyMHz, bandwidthKHz, spreadingFactor) }

    /// The same network as these settings, whatever their coding rate.
    public func matches(_ r: RadioSettings) -> Bool {
        abs(r.frequencyMHz - frequencyMHz) < 0.0005 && abs(r.bandwidthKHz - bandwidthKHz) < 0.05 && r.spreadingFactor == spreadingFactor
    }
}

extension RadioProfileStore {
    /// A kept network key's name: your saved network's ("MeshCore Południe"), else its settings.
    public func name(forNetwork key: String) -> String {
        guard let n = NetworkKey(key) else { return key.isEmpty ? String(localized: "Not known") : key }
        return profiles.first { n.matches($0.radio) }?.name ?? n.label
    }
}

/// What was heard, as seen from the network the radio is on: the nodes heard on it (and before networks
/// were kept, which count everywhere), every node once whatever the network, those heard only on other
/// networks, and the other networks with their nodes.
public struct HeardByNetwork: Sendable {
    /// on this network, or not known: one per node, the most recently heard
    public let here: [HeardNode]
    /// one per node, wherever it was heard last
    public let anywhere: [HeardNode]
    /// keys of nodes heard only on other networks
    public let onlyElsewhere: Set<String>
    /// the other networks, most recently heard first
    public let others: [Elsewhere]

    public struct Elsewhere: Identifiable, Hashable, Sendable {
        public let network: String
        public let nodes: [HeardNode]
        public var id: String { network }
        public var lastHeard: Date { nodes.map(\.lastHeard).max { $0.timeIntervalSince1970 < $1.timeIntervalSince1970 } ?? .distantPast }
    }

    /// - network: the radio's (nil: not known yet, and everything counts as here)
    public init(_ all: [HeardNode] = [], network: String?) {
        here = HeardNode.newestPerNode(all.filter { network == nil || $0.network == network || $0.network.isEmpty })
        anywhere = HeardNode.newestPerNode(all)
        onlyElsewhere = Set(all.map(\.key)).subtracting(here.map(\.key))
        others = Dictionary(grouping: all.filter { !$0.network.isEmpty && $0.network != network }, by: \.network)
            .map { Elsewhere(network: $0.key, nodes: $0.value) }
            .sorted { $0.lastHeard.timeIntervalSince1970 > $1.lastHeard.timeIntervalSince1970 }
    }
}
