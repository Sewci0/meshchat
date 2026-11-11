# MeshChat for iOS

A native iPhone and iPad app for MeshCore radios, over **Bluetooth** or **WiFi**, with its own history and
no internet needed. It works with stock MeshCore companion firmware and with [MeshChat firmware](../firmware),
and it doesn't need anything else in this repository. Design: [DESIGN.md](DESIGN.md).

## Layout

| Path | What |
|---|---|
| `Sources/MeshCoreKit` | The MeshCore companion protocol: every command, reply and push; raw packets, adverts, channel crypto; Bluetooth (CoreBluetooth) and WiFi (Network.framework) transports; `MeshCoreClient`, an actor that keeps one command in flight and completes it only on the replies it expects. |
| `Sources/MeshChatCore` | The app's logic and history (SQLite via GRDB): queue sync (including messages another app fetched), the packet log, linking messages to the packets they came in, channel resends until a repeater is heard, DM tries (route, route, then flood) with round trips, route history, listening to hashtag channels, repeater queries, joining and leaving rooms. |
| `Sources/MeshChatUI` | The screens (SwiftUI), with an `@Observable` app model. Builds for macOS too, so the compiler checks them without Xcode. The map engine comes in from the app through `MapProvider`. |
| `App/` | The iOS app: entry point, notifications, the map (MapLibre Native with OpenFreeMap vector tiles, offline regions), privacy manifest, icon, and the String Catalogs (English, Polish, Czech). |
| `project.yml` | XcodeGen spec for `MeshChat.xcodeproj` (MeshChatUI from this package, MapLibre from its own). |
| `Sources/meshcore-cli` | A Mac command-line tool that checks a radio with the same code, read-only. |
| `Tests/` | Swift Testing suites, against `SimulatedRadio` (in MeshCoreKit), which answers like MeshCore's firmware and also runs the demo. |

## Build and run

```bash
brew install xcodegen
xcodegen                 # writes MeshChat.xcodeproj
open MeshChat.xcodeproj  # choose your team under Signing, then run
```

Needs Xcode 26 or later (Xcode 27, on macOS 26.6 or later, for a device running iOS 27). The Simulator
can connect over WiFi; Bluetooth needs a real device.

**Without a radio:** "Try without a radio" on the connect screen (or the `-demo` launch argument) runs a
made-up mesh around Gdańsk, Gdynia and Sopot on a simulated radio, with its own history in memory and its
own settings; nothing of yours is read or changed. For the App Store screenshots, `-demoScreen` opens it on
`channel`, `route` (a message's route), `map`, `reach` (a reach check), `nodes` or `networks`.

**Translations:** strings live in `App/Localizable.xcstrings` (the package's too: SwiftUI and
`String(localized:)` look them up in the app's bundle), `Widgets/Localizable.xcstrings` and
`App/InfoPlist.xcstrings`. Xcode doesn't extract strings from the package by itself; after changing them,
build with `SWIFT_EMIT_LOC_STRINGS=YES` and run `xcrun xcstringstool sync App/Localizable.xcstrings
--stringsdata …` over the build's `.stringsdata` files. The packet anatomy and the admin command
catalogue stay in English.

## Tests

```bash
./test.sh        # same as `swift test`, also with only the Command Line Tools installed
./check-ios.sh   # type-checks the iPhone-only code (UIKit parts, the app target, the map) without Xcode
swift run meshcore-cli tcp meshcore.local --listen 30   # a radio over WiFi, read-only
swift run meshcore-cli scan                            # Bluetooth radios nearby
```

178 tests in 37 suites:
- **the protocol**: frames byte for byte (including the reach check, trace and node location), message
  text types as the radio sends them (room posts with their author, a command's answer), telemetry
  requests and readings (Cayenne LPP, negative coordinates, unknown types), the radio
  settings frames (radio parameters keeping repeat on, timing, auto-add, flood region, telemetry modes), channel
  crypto against IDs a real radio reported, WiFi framing, packets, text limits;
- **the engine against a simulated radio**: channel echoes and resends, DM tries and receipts, route reset
  on the last try, linking queued messages to their packets, listened channels, room posts and leaving,
  messages another app fetched, learned routes, joining and leaving channels (and a full radio), adding
  and removing contacts (many at once, stopping partway, starring one without changing when it was heard, starring the people you message), asking for readings (a person
  directly, a repeater as a guest, someone who doesn't share), a repeater's status and neighbours (and flooding when its saved route stops
  answering), admin commands and their answers (passwords masked), joining a room as a guest, a refused
  login, deleting history, the Bluetooth PIN, restarting the radio, switching away from (or giving up on) a radio
  that doesn't answer, a repeater heard on two networks;
- **the logic behind the screens**: repeater analysis (a packet heard along several paths counted once) and a repeater gone quiet, message copies and clock
  skew, the rooms browser, the nodes list (merging, sorting, accent-insensitive search), map points, a
  message's route on the map and marker clustering, offline region sizes, packet anatomy and airtime
  (matching the web app), QR links, saved networks (matching the radio, unique names, reordering, share
  links), following the radio's network (naming it, what each network heard, heard nodes kept per network
  and the old records moved over, where a conversation changed network), tidying the radio's contacts (by hops away or last heard, what always stays, longest unheard
  first, or clearing them all), the radio's auto-add hop limit as it counts it, how readings read,
  the nodes list's contact and last-heard filters, pasted coordinates, radio parameter limits, PINs,
  delivery stats; repairing room posts stored with their author's key in the text; what notifies (defaults, mentions across spellings, muting, old news, the reconnect
  backlog, the app icon's number); writing mentions (spotting "@…" as you type, completing it, whom to
  suggest); the reach check's verdicts, headline and a ping added by hand, and the last-heard badge; a repeater's signal
  chart (levels and bands for the radio's spreading factor, ranges and wording as the web app) and its last
  3 hours of activity; the map's card for a tapped node (what it says and offers for a repeater, person,
  room or home);
- **the app model**: unread state and the tab badge, rooms apart from DMs, notifications' trigger, moving
  between tabs, deleting a DM, channel or room from the chat list, what's remembered (home, read markers, the radio), reconnecting after a drop with backoff;
- **the demo and blocking**: the demo mesh connects and has its history (nothing dated in the future, your
  repeater found); a blocked sender's channel messages and DMs are hidden and don't notify.

`meshcore-cli` was run against a MeshChat radio: device info, 344 contacts in 0.9 s, 8 channels, and live
adverts matching the radio's own packet log.

`check-ios.sh` builds the screens as Mac Catalyst against the iOS frameworks in the macOS SDK, and
type-checks `App/` against MapLibre's headers (downloaded at the version `project.yml` names, checksum
verified). The camera scanner isn't on Catalyst, so it's the one part only Xcode checks.

On macOS 15 and later, a tool started from a background process may be denied the local network (Local
Network privacy). `meshcore-cli nc <host>` carries the same bytes through `/usr/bin/nc`, which is exempt.

## Status

Running on iPhone and in the Simulator, in TestFlight:
- **connecting** over Bluetooth (scan, PIN pairing by iOS) or WiFi; reconnecting on launch, on return, and
  after a drop or a radio restart (2, 4, 8, 16, then every 30 s)
- **chats**: channels, listened channels, rooms, direct messages; unread markers and a tab badge; mentions
  highlighted; long-press a message for details, copy, reply with a mention, message the sender privately,
  show on the map, send again (a channel message nobody repeated), delete
- **sending** with the web app's delivery states: sent / repeated ×N / not heard; delivered (try N) / no receipt
- **message details**: every copy heard with timing and signal, the route with repeater names and distances,
  the sender's clock, the packet field by field with its airtime
- **route details** with history, delivery stats and Reset path; **room details** with your role, posts,
  status, joining (guest or password) and leaving; a **rooms browser** of room servers heard on the mesh
- **channels**: join a hashtag or private channel, listen without joining, leave; delete a conversation's
  messages
- **map** (MapLibre, OpenFreeMap vector tiles): contacts and heard nodes by kind, home, a message's route;
  **offline regions** around home or the area on screen, with sizes before downloading
- **repeaters**: analysis from the packet log (heard directly or further along, your repeater and a
  warning when it goes quiet), each with activity, signal, who enters the mesh there, links, and live
  status and neighbours on request; with the admin password, every admin command: restart, adverts,
  clock, settings (read and change), access, and a command line with the full catalogue
- **nodes**: contacts and heard nodes, sortable and filterable, each with details, message, route, map,
  add or remove
- **per network**: Nodes, the map, Repeaters, the packet log and the reach check show what was heard on
  the network the radio is on; contacts heard only on another are listed apart, other networks' nodes are
  behind a row of their own, and a conversation marks where the network changed. Chats, contacts, rooms
  and routes are the same whatever the network
- **contacts by QR code**: your own code, adding from the camera, a picture of a code or a pasted link;
  meshcore:// links opened from other apps
- **settings**: name, flood and zero-hop adverts, location visibility; network presets and custom
  parameters, TX power, the Bluetooth PIN, restarting the radio; home location (typed, pasted from a maps
  app, or this device's location); the packet log, live with pause and filters
- **notifications** for DMs, room posts and mentions while in the background; tapping one opens it
- **blocking** a sender (from a message or a contact): their channel messages and DMs are hidden on this
  iPhone; unblock in Settings › Blocked
- **a demo** for trying the app without a radio; **acknowledgements** for MapLibre, GRDB, OpenStreetMap,
  OpenFreeMap and MeshCore
- **in English, Polish and Czech**

Still to do:
- UI tests for the main flows
- iPad-specific layouts beyond the split view in Chats
- firmware updates (MeshChat firmware's web app does these over WiFi from the radio's own page)
