import Foundation
import Testing
@testable import MeshChatCore
import MeshCoreKit

// How a node's readings read on screen.

@Suite("Readings")
struct TelemetryTextTests {
    @Test func labelsAndValues() {
        let r = [TelemetryReading(channel: 1, kind: .voltage, values: [4.12]),
                 TelemetryReading(channel: 2, kind: .voltage, values: [12.6]),
                 TelemetryReading(channel: 1, kind: .temperature, values: [-3.5]),
                 TelemetryReading(channel: 2, kind: .humidity, values: [45.5]),
                 TelemetryReading(channel: 2, kind: .humidity, values: [45]),
                 TelemetryReading(channel: 1, kind: .location, values: [50.0647, 19.945, 230]),
                 TelemetryReading(channel: 1, kind: .presence, values: [1])]
        #expect(r.map(\.label) == ["Battery", "Voltage · sensor 2", "Temperature", "Humidity · sensor 2", "Humidity · sensor 2",
                                   "Position", "Presence"])
        #expect(r.map(\.text) == ["4.12 V", "12.60 V", "-3.5 °C", "45.5 %", "45 %", "50.0647, 19.9450 · 230 m", "on"])
        #expect(r[5].position == Position(latitude: 50.0647, longitude: 19.945))
        #expect(TelemetryReading(channel: 1, kind: .location, values: [0, 0, 0]).position == nil)   // no fix
    }
}
