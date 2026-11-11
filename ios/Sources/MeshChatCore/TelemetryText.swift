import Foundation
import MeshCoreKit

/// How a reading reads: "Battery" 4.12 V, "Temperature" 21.5 °C, "Position" 50.1234, 19.1234.
extension TelemetryReading {
    public var label: String {
        let name: String = switch kind {
        case .voltage: channel == Self.ownChannel ? String(localized: "Battery") : String(localized: "Voltage")
        case .temperature: String(localized: "Temperature")
        case .humidity: String(localized: "Humidity")
        case .pressure: String(localized: "Pressure")
        case .illuminance: String(localized: "Light")
        case .presence: String(localized: "Presence")
        case .location: String(localized: "Position")
        case .altitude: String(localized: "Altitude")
        case .percentage: String(localized: "Level")
        case .current: String(localized: "Current")
        case .power: String(localized: "Power")
        case .energy: String(localized: "Energy")
        case .frequency: String(localized: "Frequency")
        case .distance: String(localized: "Distance")
        case .direction: String(localized: "Direction")
        case .concentration: String(localized: "Concentration")
        case .generic: String(localized: "Value")
        case .analogInput: String(localized: "Analog input")
        case .analogOutput: String(localized: "Analog output")
        case .digitalInput: String(localized: "Digital input")
        case .digitalOutput: String(localized: "Digital output")
        case .toggle: String(localized: "telemetry.switch", defaultValue: "Switch", comment: "Telemetry: an on/off switch sensor (a noun)")
        case .time: String(localized: "Clock")
        case .accelerometer: String(localized: "Acceleration")
        case .gyrometer: String(localized: "Rotation")
        case .colour: String(localized: "Colour")
        }
        // channel 1 is the node itself; others are its sensors
        return channel == Self.ownChannel ? name
            : String(localized: "\(name) · sensor \(channel)", comment: "A reading from one of a node's sensors: \"Voltage · sensor 2\"")
    }

    public var text: String {
        let v = values.first ?? 0
        func f(_ format: String, _ x: Double) -> String { String(format: format, x) }
        switch kind {
        case .voltage: return f("%.2f V", v)
        case .temperature: return f("%.1f °C", v)
        case .humidity: return v.rounded() == v ? f("%.0f %%", v) : f("%.1f %%", v)
        case .pressure: return f("%.1f hPa", v)
        case .illuminance: return f("%.0f lx", v)
        case .presence, .toggle, .digitalInput, .digitalOutput:
            return v != 0 ? String(localized: "on", comment: "A switch or presence reading") : String(localized: "off", comment: "A switch or presence reading")
        case .location:
            let alt = values.count > 2 && values[2] != 0 ? f(" · %.0f m", values[2]) : ""
            return f("%.4f, ", v) + f("%.4f", values.count > 1 ? values[1] : 0) + alt
        case .altitude: return f("%.0f m", v)
        case .percentage: return f("%.0f %%", v)
        case .current: return f("%.3f A", v)
        case .power: return f("%.0f W", v)
        case .energy: return f("%.3f kWh", v)
        case .frequency: return f("%.0f Hz", v)
        case .distance: return f("%.3f m", v)
        case .direction: return f("%.0f°", v)
        case .concentration: return f("%.0f ppm", v)
        case .generic: return f("%.0f", v)
        case .analogInput, .analogOutput: return f("%.2f", v)
        case .time:
            return v > 0 ? Date(timeIntervalSince1970: v).formatted(date: .abbreviated, time: .shortened)
                : String(localized: "not set", comment: "A clock reading with no time set")
        case .accelerometer: return values.map { f("%.2f", $0) }.joined(separator: ", ") + " g"
        case .gyrometer: return values.map { f("%.1f", $0) }.joined(separator: ", ") + " °/s"
        case .colour: return "RGB " + values.map { f("%.0f", $0) }.joined(separator: ", ")
        }
    }

    /// For a position reading: where, unless it's 0,0 (no fix).
    public var position: Position? {
        guard kind == .location, values.count > 1, values[0] != 0 || values[1] != 0 else { return nil }
        return Position(latitude: values[0], longitude: values[1])
    }
}
