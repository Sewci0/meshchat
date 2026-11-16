# Changelog

What changed in MeshChat for iOS, by App Store version, newest first. (The firmware's history is in git.)

## 1.1

Build 3, November 2026.

### New

- **Links in messages** are tappable, with a preview in the message's bubble: the page's picture, title
  and site. Previews load by themselves only in direct messages, and with a tap in channels and rooms,
  because fetching one contacts the link's website and on the mesh anyone can post a link. Choose where
  they load in Settings › Link previews.
- **Lock screen:** your last message shows where it went, how it went in full ("repeated ×3", "delivered
  in 3.4 s") and what you wrote. When nothing is unread, the card shows people heard in the last hour,
  and the radio's airtime and uptime (firmware that reports them).
- **Repeaters:** reception bars for each repeater heard directly, from its latest packets.
- **Map:** a repeater's links show only it and the repeaters at their other ends, with thicker lines;
  "Show on map" on a repeater's Links tab opens that view.
- **Mentions** read "@Name" in bold while you write, as they do in the bubbles.

### Changed

- **Connection settings:** Bluetooth radios and WiFi radios are in separate lists, and the Bluetooth PIN
  has a page of its own.
- **Heard directly** lists repeaters heard in the last hour, freshest then strongest. A repeater that has
  gone quiet is judged on the last two hours, and older times show their date.
- **Yours** follows your last five messages, so it changes when you move.
- **Home location** saves by itself, and distances update at once.
- Chats shows the radio as last synced while it reconnects, instead of a half-loaded list.
- The message field no longer has an "@" button: type "@" to mention someone.
- The map stays where you left it when you come back from a page opened over it.

### Fixed

- A channel message could show no copies in its details when it arrived while the radio was connecting.
- A room removed from the radio's contacts stayed in Chats under its key; a removed person lost their name.
- The "new messages" button sometimes didn't reach the newest message.
- Confirmation dialogs could appear away from the control that opened them.

## 1.0

13 November 2026. The first release.
