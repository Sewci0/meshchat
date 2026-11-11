# MeshChat for iOS — design

A native iPhone and iPad app with the same features as the web app built into MeshChat firmware ([`../firmware`](../firmware)), talking to a MeshCore
companion radio directly over **Bluetooth** or **WiFi** (stock MeshCore firmware or MeshChat's). It keeps
its own history, works with no internet, and stays connected in the background.

## Goals

- **Feature parity with the web app**: channels (join, leave, listen to hashtag channels without joining),
  DMs with delivery details, route details and Reset path, room servers (join, posts, status, browser),
  repeater analysis and live status, nodes, packet log, message details down to the bytes, contacts by QR
  code, radio settings and network presets, flood adverts.
- **Offline first**: everything works with no internet. The map uses offline regions downloaded once; the
  public map (map.meshcore.io) is an optional extra, cached when fetched.
- **Native where it matters**: Bluetooth that stays connected in the background, local notifications for
  DMs and mentions, the camera for QR codes, Dynamic Type, VoiceOver, dark mode, iPad split view.

## Platform choices

| | Choice | Why |
|---|---|---|
| UI | SwiftUI, iOS 17+ | Observation (`@Observable`), `NavigationSplitView` for iPhone and iPad, `.searchable`, `ContentUnavailableView`. |
| Language | Swift 6, strict concurrency | Data races caught at compile time; radio I/O in actors. |
| Radio | `MeshCoreKit` (this repo) | The companion protocol, written from MeshCore's source (`examples/companion_radio/MyMesh.cpp`). No UI; builds and tests on macOS too. |
| Bluetooth | CoreBluetooth, `bluetooth-central` background mode | Nordic UART service `6E400001-…`; pairing (the radio's PIN) is iOS's own prompt. |
| WiFi | Network.framework (`NWConnection`) to port 5000 | Local network permission; an address, or `meshcore.local` resolved over mDNS. |
| Storage | SQLite via [GRDB](https://github.com/groue/GRDB.swift) | Fast queries over tens of thousands of messages and packets, migrations, observation; builds outside Xcode (SwiftData's macros don't). |
| Maps | [MapLibre Native](https://github.com/maplibre/maplibre-native) + OpenFreeMap vector tiles | Offline packs for a region you choose; no API key; open data (OpenStreetMap). MapKit can't keep third-party maps offline. |
| Crypto | CryptoKit (SHA-256, HMAC) + CommonCrypto (AES-128-ECB) | Reading hashtag channels the radio hasn't joined, packet fingerprints. |

No analytics, no accounts, no servers. A privacy manifest (`PrivacyInfo.xcprivacy`) declares only the
required-reason APIs used (UserDefaults).

## Architecture

```
MeshChat (app target)
  MeshChatApp     entry point, notifications
  MapLibreMaps    the map and offline regions (MapLibre Native), behind MapProvider
        │
MeshChatUI (package)
  Screens     Chats · Map · Repeaters · Nodes · Settings, and the sheets and pages they open
  AppModel    @Observable, @MainActor: what the views show; follows the engine; tabs, reconnecting
        │
MeshChatCore (package)
  Engine      actor: the logic the radio's web app has (sync, retries, linking copies, route history, rooms,
              listening, repeater queries), driven by radio events, writing to the store
  Store       GRDB: messages, packets, heard nodes, rooms, routes, listened channels, live answers
  Logic       repeater analysis, message details, rooms browser, nodes list, map content, offline
              regions, packet anatomy, QR links, presets (all testable without a UI)
        │
MeshCoreKit (package)
  MeshCoreClient  actor: one command at a time, each waiting for the reply codes it expects;
                  pushes as an AsyncStream of events
  Transports      BluetoothTransport (CoreBluetooth) · TCPTransport (Network.framework)
  Codec           commands, replies and pushes ⇄ typed values; raw packets; adverts; channel crypto
```

**Replies go to every connection** on MeshChat's firmware (and on any radio with several apps attached),
so the client accepts only the reply codes the pending command expects and ignores the rest. Frames of
another app's command never complete ours.

**One WiFi client at a time**: the radio drops the previous TCP client when a new one connects. The app
says so when it connects over WiFi, and reconnects with backoff when dropped.

## Screens (tab bar; Chats is a split view on iPad)

- **Chats**: channels, listened channels, rooms and DMs, with unread state and a tab badge. A conversation
  shows messages grouped by sender with signal, hops and delivery state; long-press for Details, Copy,
  Reply (with a mention), Message privately, Show on map, Send again, Delete. The ⋯ menu opens Route
  details (DMs) or Room details, Leave channel, Stop listening, Delete messages. The + menu: new message,
  join or listen to a channel, room servers, contacts by QR code.
- **Map**: contacts and heard nodes by kind, home, a message's route on request; a card for the tapped
  node (message, route, repeater page). Offline regions from the toolbar.
- **Repeaters**: the list (yours first, heard directly, further along), each with overview, people, links,
  and live status and neighbours.
- **Nodes**: contacts and heard nodes, sortable and filterable; each with details and actions. Contacts
  heard only on another network are listed apart, and other networks' nodes are behind a row.

Nodes, the map, Repeaters, the packet log and the reach check follow the network the radio is on (or was,
while it isn't connected): heard nodes are kept per node and network, and records from before networks
were kept count on every network. Chats, contacts, rooms and routes are shared; a conversation shows a
divider where the network changed.
- **Settings**: your node (name, adverts, location visibility, your QR code), the radio (network presets,
  parameters, TX power, Bluetooth PIN, restart), the connection, home location, the packet log.
- **Connect**: shown until a radio is chosen: nearby Bluetooth radios (by signal), or a WiFi address.

Destructive or outward actions ask first: flood adverts, switching networks, restarting the radio,
leaving a channel or room, resetting a path, removing a contact, deleting messages.

## Background and notifications

With the `bluetooth-central` background mode the connection survives the app being in the background, so
messages keep arriving and are stored. New DMs, room posts and channel mentions post a local notification;
tapping it opens the conversation. WiFi connections are suspended by iOS in the background; the app
reconnects and drains the radio's queue (`CMD_SYNC_NEXT_MESSAGE`) when it returns. A dropped link is
retried after 2, 4, 8, 16, then every 30 seconds.

## Permissions (Info.plist)

`NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription` with `NSBonjourServices`
(`_http._tcp`), `NSCameraUsageDescription` (QR codes), `NSLocationWhenInUseUsageDescription` (optional:
"use my location" for home), `UIBackgroundModes: bluetooth-central`, and the `meshcore` URL scheme for
contact and channel links. App Transport Security allows local networking (`NSAllowsLocalNetworking`);
the only internet traffic is map tiles over HTTPS.

## Testing

- Swift Testing suites for the protocol, the engine (against `Tests/Support/FakeRadio`, which answers
  like MeshCore's firmware), the logic behind each screen, and the app model: `./test.sh` on macOS.
- `check-ios.sh` type-checks the iPhone-only code without Xcode (Mac Catalyst against the macOS SDK's iOS
  frameworks, and MapLibre's headers).
- `meshcore-cli` (a macOS command-line tool in this package) connects to a radio over WiFi or Bluetooth and
  prints what it hears: the transports and client checked against real hardware.
- With Xcode: the Simulator (WiFi only; Bluetooth needs a device) and UI tests for the main flows.

## Building

`brew install xcodegen && xcodegen` generates `MeshChat.xcodeproj` from `project.yml`; open it in Xcode,
choose your team for signing, run. A device running iOS 27 needs Xcode 27 (macOS 26.6 or later).
