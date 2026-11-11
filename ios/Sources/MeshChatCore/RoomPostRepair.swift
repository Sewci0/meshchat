import Foundation
import MeshCoreKit

/// Room posts stored before the radio's text type was read right. The radio sends the type as a plain
/// number (2 for a signed room post), but the app shifted it as if it were a packet's flags byte, so
/// posts were taken as plain text: the author's 4-byte key prefix stayed at the front of the text, and
/// its bytes that aren't valid UTF-8 became U+FFFD when decoded ("J\u{2}\u{FFFD}\u{FFFD}Test 3").
///
/// This takes those 4 bytes back off, and keeps as much of the author's ID as survived.
public enum RoomPostRepair {
    /// The post without its author prefix, and the prefix's leading bytes as hex up to the first one
    /// lost (nil when the first is). Nil when the text is too short to hold a prefix and a post, or
    /// a character runs across the prefix's end (valid text can't start in the middle of one).
    ///
    /// Each U+FFFD is counted as one byte: an invalid byte on its own is replaced singly; only a
    /// cut-off multi-byte sequence (rare in 4 random bytes) is replaced as one for several.
    public static func split(_ text: String) -> (author: String?, text: String)? {
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        var bytes = 0
        var known: [UInt8] = []
        var lost = false
        while bytes < 4, i < scalars.endIndex {
            let s = scalars[i]
            if s == "\u{FFFD}" {
                bytes += 1
                lost = true
            } else {
                let utf8 = Array(String(s).utf8)
                bytes += utf8.count
                if !lost { known += utf8 }
            }
            i = scalars.index(after: i)
        }
        guard bytes == 4, i < scalars.endIndex else { return nil }
        return (known.isEmpty ? nil : Data(known).hex, String(scalars[i...]))
    }
}
