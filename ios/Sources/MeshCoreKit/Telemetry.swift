import Foundation

/// One reading in a node's telemetry: what it measures, on which channel (1 is the node itself, others its
/// sensors), and the value (three for a position or an axis triple).
public struct TelemetryReading: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case digitalInput, digitalOutput, analogInput, analogOutput, generic, illuminance, presence, temperature, humidity
        case accelerometer, pressure, voltage, current, frequency, percentage, altitude, concentration, power, distance
        case energy, direction, time, gyrometer, colour, location, toggle
    }

    public let channel: Int
    public let kind: Kind
    public let values: [Double]

    public init(channel: Int, kind: Kind, values: [Double]) {
        self.channel = channel; self.kind = kind; self.values = values
    }

    /// the node's own channel (battery, board temperature, its GPS)
    public static let ownChannel = 1
}

/// Cayenne LPP, as MeshCore sends telemetry: [channel][type][value], values big-endian, each type its
/// own size and scale (see the firmware's LPPDataHelpers.h).
public enum Telemetry {
    /// (kind, bytes per value, values, divisor, signed)
    private static let types: [UInt8: (TelemetryReading.Kind, Int, Int, Double, Bool)] = [
        0: (.digitalInput, 1, 1, 1, false), 1: (.digitalOutput, 1, 1, 1, false),
        2: (.analogInput, 2, 1, 100, true), 3: (.analogOutput, 2, 1, 100, true),
        100: (.generic, 4, 1, 1, false), 101: (.illuminance, 2, 1, 1, false), 102: (.presence, 1, 1, 1, false),
        103: (.temperature, 2, 1, 10, true), 104: (.humidity, 1, 1, 2, false),
        113: (.accelerometer, 2, 3, 1000, true), 115: (.pressure, 2, 1, 10, false),
        116: (.voltage, 2, 1, 100, false), 117: (.current, 2, 1, 1000, false), 118: (.frequency, 4, 1, 1, false),
        120: (.percentage, 1, 1, 1, false), 121: (.altitude, 2, 1, 1, true), 125: (.concentration, 2, 1, 1, false),
        128: (.power, 2, 1, 1, false), 130: (.distance, 4, 1, 1000, false), 131: (.energy, 4, 1, 1000, false),
        132: (.direction, 2, 1, 1, false), 133: (.time, 4, 1, 1, false), 134: (.gyrometer, 2, 3, 100, true),
        135: (.colour, 1, 3, 1, false), 142: (.toggle, 1, 1, 1, false),
    ]

    /// The readings, in order. Stops at a type it doesn't know (its size is unknown, so nothing after it
    /// can be read) or at a cut-off value.
    public static func decode(_ data: Data) -> [TelemetryReading] {
        let b = [UInt8](data)
        var i = 0, out: [TelemetryReading] = []
        func number(_ at: Int, _ size: Int, signed: Bool) -> Double {
            var v: UInt64 = 0
            for k in 0..<size { v = v << 8 | UInt64(b[at + k]) }
            if signed, size < 8, v & (1 << UInt64(size * 8 - 1)) != 0 { return Double(Int64(bitPattern: v) - (1 << Int64(size * 8))) }
            return Double(v)
        }
        while i + 2 <= b.count {
            let channel = Int(b[i]), type = b[i + 1]
            i += 2
            if type == 136 {   // position: latitude and longitude 3 bytes each (0.0001°), altitude 3 bytes (0.01 m), signed
                guard i + 9 <= b.count else { break }
                out.append(TelemetryReading(channel: channel, kind: .location,
                                            values: [number(i, 3, signed: true) / 10000, number(i + 3, 3, signed: true) / 10000,
                                                     number(i + 6, 3, signed: true) / 100]))
                i += 9
                continue
            }
            guard let (kind, size, count, divisor, signed) = types[type], i + size * count <= b.count else { break }
            out.append(TelemetryReading(channel: channel, kind: kind,
                                        values: (0..<count).map { number(i + $0 * size, size, signed: signed) / divisor }))
            i += size * count
        }
        return out
    }
}
