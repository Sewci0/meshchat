# MeshChat firmware (ESP32-S3)

MeshCore companion firmware for the **Seeed XIAO ESP32-S3 + Wio-SX1262** kit. It's stock MeshCore
**companion v1.18.0** (`81dbae5`) plus one patch, which adds:

- **WiFi alongside USB and Bluetooth.** The radio joins your WiFi and accepts companion apps on TCP port 5000,
  including [MeshChat for iOS](../ios) and the official MeshCore apps.
- **WiFi setup without a computer:** a setup hotspot with a page to pick a network, several saved networks, and
  an mDNS name (`meshcore-xxxx.local`).
- **MeshChat on the radio:** a web chat app served by the radio itself, with message history kept on the node,
  so no computer or phone has to stay on.
- **Firmware updates over WiFi** from that web app.

This firmware is independent of the iOS app. The iOS app works with stock MeshCore companion firmware too
(over Bluetooth, or over WiFi with any companion build that has TCP enabled), and this firmware works with any
MeshCore companion app.

| Path | What |
|---|---|
| `meshchat.patch` | The changes against MeshCore `companion-v1.18.0`: WiFi, setup hotspot, web server and API, history, updates. |
| `platformio.local.ini` | The two build environments (below). |
| `webui/` | The web app the radio serves: React 19, [shadcn/ui](https://ui.shadcn.com), Tailwind v4, Vite. Design notes in [`webui/DESIGN.md`](webui/DESIGN.md). |
| `gen_webui_assets.py` | Embeds the built web app into the firmware as gzip-compressed C arrays (`WebUiAssets.h`). |
| `tools/` | A finder for the names of hashtag channels the radio hears but can't read. |

## Builds

| PlatformIO env | What you get |
|---|---|
| `Xiao_S3_WIO_companion_radio_meshchat` | Everything: the web app, history on the radio, Bluetooth, USB and WiFi. |
| `Xiao_S3_WIO_companion_radio_usb_wifi` | A companion radio on USB and WiFi (TCP 5000) with WiFi setup, but no web app and no Bluetooth. |

### Building

You need [PlatformIO](https://platformio.org), Node.js 20 or later and Python 3. From the folder that holds
this repository:

```bash
git clone --branch companion-v1.18.0 https://github.com/meshcore-dev/MeshCore
cd MeshCore
git apply ../meshchat/firmware/meshchat.patch
cp ../meshchat/firmware/platformio.local.ini .
(cd ../meshchat/firmware/webui && npm ci && npm run build)
python3 ../meshchat/firmware/gen_webui_assets.py ../meshchat/firmware/webui/dist examples/companion_radio/WebUiAssets.h
pio run -e Xiao_S3_WIO_companion_radio_meshchat
```

Source paths compiled into log messages are rewritten so your home folder shows as `~`: the binary doesn't
carry your user name.

### Flashing

The first time, flash everything over USB (bootloader, partitions and app):

```bash
pio run -e Xiao_S3_WIO_companion_radio_meshchat -t upload
```

After that, flash only the app, so the node's identity, contacts, channels and history (in the `spiffs`
partition) stay as they are:

```bash
esptool --chip esp32s3 --port /dev/cu.usbmodem101 write_flash 0x10000 .pio/build/Xiao_S3_WIO_companion_radio_meshchat/firmware.bin
```

Or update over WiFi: in the web app, **Settings → Mesh → Radio → Update firmware…**, then pick the app-only
`firmware.bin`. The flash has two app slots (3.2 MB each): the upload goes into the spare one while the radio
keeps working (about 20 s), ESP-IDF checks the image (magic byte, chip, SHA-256), and only then does it become
the boot slot. A cut-off or damaged file is refused and the current firmware keeps running. The web app checks
a file first: it must be an ESP32-S3 app image, not a full flash image, and if it has no `MESHCHAT-BUILD:`
marker (plain MeshCore, which would remove the web app) it asks before installing. A firmware that boots but
misbehaves still needs USB to recover.

## WiFi

- **Joins your WiFi** and announces itself as **`<hostname>.local`** (default `meshcore-xxxx`, from the radio's
  hardware address) on port 5000. It always answers to its built-in `meshcore-xxxx.local` too, so renaming it
  never breaks bookmarks or the home-screen app. mDNS starts once per boot and is never restarted: on this
  ESP32 core, restarting it left the radio answering no name lookups until a reboot.
- **Several networks:** up to 8, most preferred first. It joins the most preferred one in range with a usable
  signal (−85 dBm or better), otherwise the strongest one in range. The first is mirrored into MeshCore's own
  `wifi.ssid` / `wifi.pwd`, so the CLI keeps working. Passwords never leave the radio: apps only learn whether
  one is set.
- **Setup hotspot `MeshCore-Setup-XXXX`** (password `meshcore`), with a page to pick a network, enter its
  password and set the hostname. It opens:
  - when no network is saved;
  - when the saved one doesn't connect within 45 s of boot, or is lost for 10 minutes;
  - when you **hold the button while plugging the radio in** (about 2 s). That's the button's only job on this
    screenless kit: without a display the firmware's menu presses are ignored, since pressing through an
    invisible menu could switch Bluetooth off or put the radio to sleep;
  - from the web app: Settings → *Open setup hotspot*.

  An automatic hotspot tries the saved network once a minute, only while nobody is on the hotspot, and closes
  when it's back, or after 10 minutes if nobody joined. One opened by hand stays until settings are saved or
  the radio restarts. On the hotspot the radio is at `http://192.168.4.1` and still answers to
  `<hostname>.local`. Phones show a "log in to network" sheet on joining; on iPhone, close it and choose *Use
  Without Internet* to stay connected.
- **Contacts and channels are saved safely:** to a side file that's swapped in once complete. On stock firmware
  a reset or power cut during the save, which runs 5 s after any advert, could cut the contact list short.
- **New CLI commands:** `get/set wifi.hostname`, `set wifi.setup`, `get wifi.mode`, `get wifi.rssi`.
  `get wifi.pwd` answers only "(set)" or "(not set)".

## MeshChat on the radio

With the `meshchat` build, open **`http://meshcore-xxxx.local`** (or the radio's IP address) on any device on
your WiFi. In Safari on iPhone, *Share → Add to Home Screen* makes it an app with its own icon.

- **Chat:** channels, rooms and direct messages, mentions with autocomplete, delivery status (sent, repeated ×N,
  delivered), message details (every copy heard, the route with repeater names and distances, the packet byte by
  byte), route details for each contact with **Reset path**.
- **History on the radio:** the last 2000 messages, kept in PSRAM and saved to flash (two rotating files, about
  320 KB at most), so they survive restarts.
- **Retries:** a DM is tried three times (the third as a flood); a channel message is re-sent identically up to
  twice until a repeater is heard passing it on, otherwise it's marked *not heard*.
- **Repeaters:** worked out in the browser from the radio's packet log (the last 3000 packets since the last
  restart) and the routes of saved channel messages: which repeaters you hear and which hear you, signal over
  time, who enters the mesh where, links, a warning when your repeater goes quiet, and live status and
  neighbours on request (a guest login, or a password you type and the radio doesn't keep).
- **Rooms:** join as a guest or with a password; posts arrive one at a time after login; a browser of the room
  servers heard on the mesh.
- **Listening to channels you haven't joined:** a hashtag channel's key comes from its name, so the radio can read
  any hashtag channel whose name it knows without using one of its channel slots (up to 48 listened). For every
  channel packet it can't read, it tries a built-in list of about 130 names used in Poland, and it keeps the
  latest 128 unreadable packets so a name you add is checked at once.
- **Map** with your contacts, nodes heard and a public node map, which **the radio downloads**: browsers can't
  load map.meshcore.io directly, so the radio fetches it (18 MB gzip, streamed), keeps nodes within 90 km of
  home seen in the last 30 days, and saves them to flash every 12 hours. The download is checked against Let's
  Encrypt's ISRG Root X1 certificate.
- **Networks:** switch between the Polish MeshCore networks (MeshCore Południe, SF6; MeshCore Polska, SF8) or
  custom settings within 863–870 MHz. Each network keeps its own channel history, packet log, repeaters and map;
  direct messages and contacts are shared.
- **Phone apps keep working.** Bluetooth stays on (pairing PIN `123456` until you set your own in Settings →
  Bluetooth), and over WiFi one app at a time can connect on port 5000. MeshCore queues incoming messages until
  an app fetches them; the web app records each message as it's queued and leaves the queue to the apps, so they
  still receive everything. Messages sent from those apps appear in the web history as well.
- **Memory:** MeshCore's main object (117 KB, mostly the contact table) moves to PSRAM in this build
  (`MESH_IN_PSRAM`), leaving about 125 KB of internal RAM for WiFi, Bluetooth, the web server and TLS.
  `GET /api/device/health` shows memory, storage and the last reset reason.

There's no offline mode or push notifications: those need a service worker, which browsers only allow over
HTTPS, and the radio serves plain HTTP on your LAN.

## Developing the web app

```bash
cd firmware/webui
npm ci
MESHCHAT_BACKEND=http://meshcore-xxxx.local npm run dev   # hot reload; your radio's name or IP address
npm run build                                       # type-checks, then writes dist/
```

Every package is pinned to an exact version and locked in `package-lock.json`. Everything, fonts included, is
bundled, so the app works without internet; only map tiles and the public-node overlay need a connection.
After changing it, rebuild the firmware (above) to put it on the radio.

## Finding hashtag channel names

`tools/find_channel_names.py` downloads the packets the radio heard but couldn't read and tries names
against them: a word list plus every name up to 4 characters, each checked against the packet's authentication
tag and then decrypted, since with only 3 bytes to check about one random name in 17 million passes by chance.
On a Mac, `--fast 7 --variants --listen` searches far more with `tools/chanfind.c` (CommonCrypto, all cores):
every name up to 7 characters and about 150 million dictionary and Polish names, then adds what it finds to
the radio. Private channels use random secrets and can't be found this way, by design.

```bash
uv run firmware/tools/find_channel_names.py --radio http://meshcore-xxxx.local
```

## Security

There's no login: anyone on your WiFi can open the web app and send messages as you, and TCP port 5000 (the
companion protocol) is open too, as with MeshCore's own WiFi firmware. Use a network you trust. The API only
answers to the radio's own address and `.local` name (against DNS rebinding) and refuses cross-origin writes
(CSRF); pages use a strict Content-Security-Policy, and mesh content is shown as text, never HTML. WiFi
passwords are never shown back, and repeater passwords are sent to the repeater and not stored.
