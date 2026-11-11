# MeshChat UI — design notes

Built with shadcn/ui (Radix + Tailwind v4), React 19, TanStack Query, React Router.

## Where it runs

The radio serves it. MeshCore companion firmware with the MeshChat patch (`../meshchat.patch`) runs the HTTP API under `/api` and live events on the `/ws` WebSocket, and carries the built UI inside the firmware image. The UI talks to nothing else, apart from OpenStreetMap's map tiles.

- **Build:** `npm run build` type-checks and writes the UI to `dist/` (not committed). `../gen_webui_assets.py` turns `dist/` into the C arrays the firmware embeds.
- **Develop:** `npm run dev` serves the UI locally with hot reload and proxies `/api` and `/ws` to a radio running the MeshChat firmware on your network: `MESHCHAT_BACKEND=http://<radio>` picks which one (default `http://meshcore.local`). The radio only accepts requests addressed to itself from its own origin, so the proxy rewrites Host and Origin to match.

## Who it's for, what they do most

One person at a desk, chatting on a local LoRa mesh. In order of frequency:

1. Read and write in channels (Public, #test), reply to someone, tag people.
2. DM a specific person.
3. Look at the map: who is where, which route a message took.
4. Understand the network: which repeaters carry traffic, who uses them, are they healthy.
5. Occasionally: rename, advertise, join a channel, check raw packets.

So chat is the home screen and the sidebar is a conversation list (Slack/Discord pattern). Tools are one click away but don't compete with conversations.

## Information architecture

```
Sidebar                         Main (routed, so back/forward and links work)
├─ Node card (name, status)     /c/chan:0          Chat
├─ ⌘K Search                    /c/dm:<key>        Chat (DM)
├─ Channels  [+]                /map               Map
├─ Rooms  [+]                   /c/dm:<room key>   Chat (room)
├─ Direct messages  [+]         /repeaters/:key?   Repeaters (list + detail)
├─ Explore                      /nodes             Nodes
│   Map · Repeaters · Rooms     /rooms             Rooms (browser)
│   · Nodes                     /packets           Packets
│   · Packets                   /settings          Settings
└─ Footer: visibility + Settings
```

- **Mobile (<768 px):** the sidebar becomes a sheet behind a menu button in every page header.
- **⌘K command palette:** jump to any channel, room, person, repeater or page, or run actions (send advert, join channel, join room).

## Principles

- **Say what's true, including uncertainty.** Route hops that are a 1-byte guess show "?"; approximate positions are visibly approximate (dashed); "delivered" only after an ACK.
- **Explain consequences before transmitting.** A flood advert gets a confirmation that says what it does. DMs before your first advert show why they can't be read yet, with the fix one click away.
- **No dead ends.** Every name leads somewhere (message, map, repeater). Every empty state says why it's empty and what will fill it.
- **Live, not loud.** WebSocket updates flow into the query cache. New messages don't yank the scroll position if you've scrolled up; a "new messages" pill appears instead.
- **Accessible by default.** Radix primitives (focus, ARIA, keyboard), visible focus rings, colour never the only signal, `prefers-reduced-motion` respected.
- **Untrusted text stays text.** Everything from the mesh is rendered as React text nodes; Leaflet gets DOM via portals, never HTML strings.

## Key screens

**Chat**
- Messages are grouped by sender (same person within 5 min). Each group has an avatar with initials, and the name opens a menu: Message privately / Show on map / Mention.
- `@[Name]` tags render as chips; messages that mention you are highlighted.
- Outgoing status uses icons with tooltips: sending → sent → heard repeated ×N / delivered ✓ / no receipt.
- The composer has `@` autocomplete (Command list) and a byte counter that appears near the 150-byte limit. Enter sends.
- Switching conversations stays quick: only the newest 50 messages are drawn at first (more if the first unread one is further back), and older ones are added 100 at a time once you scroll within a screen of the top, or with **Show earlier messages**, keeping the message you're reading in place. Drawing all 300 of a busy channel blocked the app for about half a second on every switch. The loading placeholder appears only after 400 ms, and touching a sidebar link starts loading its messages before the tap completes.

**Map**
- Full-bleed map with a floating Layers card (switches plus legend).
- Markers open popups with actions (Message, Repeater details). An active route or link overlay shows as a dismissible chip.

**Message details** (`components/message-details.tsx`, `lib/packet-anatomy.ts`)
- A right-hand sheet (full width on phones) from a message's ⋯ menu. It refreshes every 4 s while open, since copies keep arriving.
- Its sections, in order: the message, an at-a-glance grid (time, clock skew, hops, signal, copies, attempt or status), the route (vertical steps with ID chips), copies (a table; tap one to see its bytes), encryption and packet details, and the bytes field by field with coloured swatches. A line at the end says how far back the packet log goes.
- Wide content never scrolls sideways: hex wraps anywhere, and the table truncates names.
- The packet section starts with a summary: total bytes of 255, airtime, and a byte-proportional bar with a legend. Airtime uses RadioLib's SX126x formula with MeshCore's preamble (32 symbols at SF8 and below), so it matches the radio. The summary also shows routing and payload bytes (of 184), how many hops the ID size allows (64-byte path ÷ ID size), and what the path costs in airtime.
- Below it, each field in turn. The header and path-length bytes are shown as named bit groups (version, payload type, route; ID size, hops). The path is split into repeater ID chips with names. For the ciphertext, a bar shows what's inside once decrypted: timestamp, flags (type, attempt), text and padding.
- Dropdown menus size to their content, at least as wide as the button that opens them and never wider than the screen, so items under a small ⋯ don't wrap.

**Route details** (`components/route-sheet.tsx`)
- A right-hand sheet, opened from the DM or room header's subtitle (which names the route) or **⋯ → Route details**. The ⋯ menu also has **Reset path**.
- Sections: an at-a-glance grid (hops or flood, learned, recent DMs delivered, median round trip on the route and by flood, route changes); the route as vertical steps (you → each repeater → them) with ID chips, ambiguity, leg distances and each repeater's recent relaying (amber when quiet or unheard); history (learned, re-learned, the PATH packet that brought it, the route before, the last reset and by whom); your recent messages (counts, then the last eight with outcome, try, flood or route per try, round trip); airtime for a 50-character DM; Reset path with when to use it.
- A saved route runs from you to them, so `resolveRoute` resolves it reversed (resolvePath names hops from the far end) and turns it back.
- Warnings come from the data: two or more of the last five messages without a receipt suggest a reset; no receipts at all, even by flood, point at their radio not having your key or being out of range (with when your advert went out and theirs arrived).
- Messages from before tracking have no per-try detail and are counted as "delivered (older, no detail)" rather than guessed.

**Rooms** (`components/rooms.tsx`, `lib/rooms.ts`)
- A room is a contact of type room; its conversation is `dm:<key>`. The sidebar lists rooms joined here (and not left) or with posts, newest first; a room that's open but unlisted is shown while it's open.
- **Join a room**: a dialog that lists the radio's room contacts (joined ones first, then by advert), then a password form explaining guest access, that a wrong password gets no answer, and that MeshChat doesn't keep it. The radio runs the join in the background and its answer arrives as a "live" event (`waitForLive`).
- **Room chat**: posts show their author (unknown authors as "Unknown member" plus their key prefix) and the room's time of posting, with "synced …" when they arrived later. Your posts say **posted** once the room confirms them. Until you're a member, a banner offers Join and the composer says why it's off; a guest or read-only role disables it with what the role allows. No advert warning: the login carries your key.
- **Room details**: a sheet with your standing, last login, posts, authors, newest post, route; membership actions (Log in again, Leave with a confirmation that explains MeshCore has no leave message); the room's status; who posts; the route with a link to Route details.
- **Rooms browser** (`pages/rooms.tsx`, Explore → Rooms, ⌘K, and a link in the Join dialog): offline, from the mesh only. It lists the radio's room contacts plus room adverts heard since it started (`state.contacts`, `state.heard`), with positions from those adverts and nothing from the public map, so every room is on your radio settings. Joined ones come first, then by distance, name, posts or last advert. Columns drop on narrow screens (You and Last advert below md, Posts and Distance below sm, Route below lg, Heard below xl); phones get them as one line under the name. A heard room that isn't a contact gets **Add & join** (POST /api/contacts as type 3, wait for the radio to list it, open the join form).
- Positions outside ±90° / ±180° count as none (`hasLoc`): a contact added without one used to carry garbage from the radio's memory.
- A message whose time is on another day than its arrival (an old room post, a late DM) shows its date.
- Alerts with an action put the text and the button on separate rows (`AlertDescription` as a grid), so the button never sits in the middle of a line.

**Settings** is grouped under small headings, in this order: *Your node* (name and adverts in one card), *Mesh* (network presets, then the radio's details and restart), *Connections* (WiFi, Bluetooth), *Map* (home) and *This app* (appearance, install). Channels aren't here: the sidebar's **+** joins or listens to them, and its dialog shows the slot count and *Heard but can't read*. A joined channel's **⋯** in the chat header leaves it.

**Update firmware** (`components/firmware-update.tsx`, Settings → Mesh → Radio): a dialog. It shows the running build and which slot an update goes to. Choosing a file checks it in the browser (size against the slot, ESP32 magic byte, ESP32-S3 chip ID, full flash image refused, `MESHCHAT-BUILD:` marker shown or warned about). The upload uses XHR, since fetch can't report upload progress; afterwards the dialog waits for `/api/device/health` to answer with a fresh uptime, then reloads.

**Composer**: a text area that wraps and grows to about six lines, then scrolls. Enter sends, Shift+Enter adds a new line, and the phone keyboard's return key reads "send". Bubbles use `wrap-anywhere`, so a long link breaks instead of widening the page. On phones the Nodes and Packets tables drop columns: on Nodes they move under the name, on Packets they hide.

**Contacts by QR code** (`components/add-contact.tsx`)
- One dialog, two tabs: *Scan a code* and *My contact*. Opened from the Direct messages **+** menu and ⌘K.
- Scanning reads a photo or picked image (`lib/qr.ts`: jsQR on a canvas, scaled down and retried larger), since the radio's http page gets no live camera. A pasted link works too. `lib/meshcore-links.ts` parses and builds the MeshCore apps' `meshcore://contact/add` and `channel/add` links.
- A result is a one-line card with its action: Add (POST /api/contacts), Message if already a contact, or Join for a channel code. An existing contact is never overwritten, since that would drop its learnt route.
- The QR libraries load on first use (about 55 KB gzip). The code is drawn dark on white in both themes, since scanners expect that.

**Repeaters**
- Master–detail layout. The list is grouped into "heard directly" and "further along the mesh", with search and a time range.
- The detail view has tabs:
  - **Overview:** tiles and 24 h activity.
  - **People:** who enters the mesh through it.
  - **Links:** repeaters it exchanges traffic with.
  - **Live:** guest-login status and neighbours.
- **Signal levels** (`snrQuality` in `lib/mesh.ts`) are graded by headroom above the decode limit for the radio's spreading factor (−2.5 dB × (SF−4)): below it (1, red), marginal 0–5 dB (2, amber), fair 5–10 dB (3, green), good 10+ dB (4, green). The thresholds are strict on purpose: only packets that got through are ever seen, so a signal just above the limit looks better than the link really is. The four-bar indicator uses these levels everywhere, with the number always shown beside it. WiFi strength maps onto the same four steps. The signal graph shades the bands (red, amber, plain, green tints) and names each one.
- **Gone quiet** (`quiet()` in `lib/repeaters.ts`): a repeater heard straight from at least 10 times, then silent for 15+ minutes while enough else arrived that 8+ packets should have been its own. Its page shows an amber alert. It says what likely happened: a strong signal that stopped means the repeater did; a weak one may be conditions. It also names the best repeater reaching you now, with distance and compass direction. For your own repeater, a one-line bar sits above the composer, dismissible until it goes quiet again. The chat starts this analysis 2.5 s after opening, so the conversation loads first.

**Nodes / Packets**
- Filterable tables. Packets is live, with a pause toggle and summary stats.

**Settings**
- Cards: Profile, Visibility (adverts, location hidden), Connection & WiFi, Bluetooth, Channels, Map home, Network (presets for the Polish networks), Radio, Appearance, Use it like an app.

**Channels**
- Listening (hashtag channels read without joining, add by name), channels it can't read (by 1-byte ID), joined channels.

## Code structure

Shared building blocks, so pages don't each re-solve the same problem:

| Where | What it's for |
|---|---|
| `components/page.tsx` | `Page` (header + body), `PageBody` (scrolling, centred column). Every page uses them. |
| `components/hint.tsx` | `Hint`: a tooltip on desktops, a tap-to-open popover on phones (no hover there). `tapToShow={false}` for buttons that do something. |
| `lib/routes.ts` | Conversation ids (`chan:`, `dm:`, `watch:#name`) and their URLs. `watch:` ids contain `#`, so links are only ever built here. |
| `lib/device.ts` | What the device can do: coarse pointer, hover, standalone (home-screen) mode, iOS, geolocation (secure pages only). |
| `lib/use-async.ts` | `useAsync()`: busy state + error/success toasts for buttons and forms. Forms that show errors inline keep their own handling. |
| `lib/use-join-channel.ts`, `lib/use-set-home.ts` | The two actions several screens share. |
| `lib/repeaters.ts` | Repeater analysis in the browser, from the radio's packet log and channel routes (the radio keeps them but has no room to analyse them): traffic, who uses which repeater, links, signal, your repeater, gone quiet. |
| `index.css` | `pt-safe`/`pb-safe`/`px-safe`/`top-safe` utilities for the notch, status bar and home indicator; finger-sized targets on touch screens. |
| `#ios-top-band` (`index.html`, `index.css`) | The installed iPhone app (iOS 26+) blurs the top of the page unless WebKit, probing 4 px below the middle of the top edge, finds a fixed element that spans 90%+ of the width, is taller than 10 px and has a background colour (`LocalFrameView::fixedContainerEdges`); then it extends that colour. The band is that element: in the HTML so it exists from the first frame, maximum z-index, `max(12px, env(safe-area-inset-top))` tall, taking hits (some iOS versions skip `pointer-events: none` in that probe), painting nothing (`background-clip: text`). The status bar style stays `default` (the page starts below an opaque bar); iOS reads it only when the icon is added. |

Rules that came from testing on an iPhone:
- The app frame is `overflow: clip`, never `hidden`: a hidden box can still be scrolled by focus or `scrollIntoView` (iOS does it when the keyboard opens), shifting the whole app.
- Anything near a screen edge pads itself with the safe-area utilities (`viewport-fit=cover`).
- Text fields are 16 px on phones (iOS zooms into smaller ones).
- Leaflet's layers sit in their own stacking context (`isolate`), or they cover the sidebar, menus and dialogs.
- Lists in pickers don't select on pointer movement on touch screens (it fights scrolling).
- Text on a coloured background (your own bubble) uses that background's foreground colour, including @mentions.
