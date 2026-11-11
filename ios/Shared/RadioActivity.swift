import ActivityKit
import Foundation

/// The radio's status as a Live Activity: on the lock screen, in the Dynamic Island and on the
/// always-on display, kept current by the app while it runs (shared by the app and the widget
/// extension that draws it). Everything added after the first version is optional, so an activity
/// left running by an older build still decodes.
struct RadioActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Link: String, Codable, Hashable {
            case connected, connecting
            /// WiFi in the background: iOS has paused the app, and the radio keeps messages till it's back
            case paused
            case offline
        }

        /// The newest unread message.
        struct Msg: Codable, Hashable {
            enum Kind: String, Codable, Hashable { case direct, room, channel }
            var from: String
            /// the channel or room (nil for a direct message)
            var place: String?
            /// nil when notifications hide message text
            var text: String?
            var at: Date
            var kind: Kind
            var mention: Bool
        }

        /// Your last message, for 10 minutes after sending it.
        struct Sent: Codable, Hashable {
            /// "heard by repeaters", "delivered", "not heard", …
            var status: String
            var at: Date
            /// true: it got through; false: it didn't; nil: still waiting
            var ok: Bool?
        }

        var link: Link
        /// connected (or offline) since
        var since: Date?
        /// conversations with unread messages (that notify every message)
        var unread: Int
        var msg: Msg?
        /// when the radio last heard anything: shows it's alive
        var heardAt: Date?
        /// packets per 5 minutes over the last hour, oldest first, up to `rateEnd`
        var rate: [UInt8]?
        var rateEnd: Date?
        var perHour: Int?
        /// median SNR of the last 15 minutes (whole dB), and 0–3 for how far above the decode floor
        var snr: Int?
        var level: Int?
        /// repeaters heard directly in the last 30 minutes
        var repeaters: Int?
        /// "your" repeater: when you last heard it directly, and whether it has gone quiet
        var rptName: String?
        var rptHeard: Date?
        var rptQuiet: Bool?
        /// the radio's battery (nil on USB power)
        var batteryMv: Int?
        var sent: Sent?
    }

    /// the radio's name or address
    var radio: String
    /// "Bluetooth" or "WiFi"
    var transport: String
}
