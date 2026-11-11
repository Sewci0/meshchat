# MeshChat

Messaging for [MeshCore](https://github.com/meshcore-dev/MeshCore), the open LoRa mesh network: text over
kilometres of radio with no mobile signal, no internet and no account.

This repository holds two independent projects. Each builds, runs and is documented on its own, and neither
needs the other:

| | What it is | Runs on | Talks to the radio over |
|---|---|---|---|
| **[`ios/`](ios)** | **MeshChat for iOS**: a native iPhone and iPad app (SwiftUI) | iPhone, iPad | Bluetooth, or WiFi (TCP 5000) |
| **[`firmware/`](firmware)** | **MeshChat firmware**: MeshCore companion firmware with WiFi setup and a web chat app served by the radio itself | Seeed XIAO ESP32-S3 + Wio-SX1262 | n/a: it *is* the radio |

```
iPhone / iPad (MeshChat for iOS) ──Bluetooth or WiFi──┐
                                                      ├── MeshCore companion radio ──LoRa── the mesh
any browser on your WiFi ──http://meshcore-xxxx.local─┘   (stock firmware, or MeshChat firmware
                                                            for WiFi and the web app)
```

- The **iOS app** works with any radio running MeshCore companion firmware: stock MeshCore over Bluetooth,
  or over WiFi with a companion build that has TCP enabled (MeshChat firmware does). It has a demo mode, so
  you can try it without a radio.
- The **firmware** works with any MeshCore companion app (the official MeshCore apps, MeshChat for iOS, and
  others) and adds a browser-based chat app of its own, so no phone or computer has to stay on.

They share no code. They do share behaviour (delivery retries, message routes, repeater analysis, per-network
history), described in each project's design notes.

## Getting started

- **iOS app:** see [`ios/README.md`](ios/README.md) to build it with Xcode, and
  [`ios/DESIGN.md`](ios/DESIGN.md) for how it works.
- **Firmware:** see [`firmware/README.md`](firmware/README.md) to build and flash it, set up WiFi, and develop
  the web app ([`firmware/webui/DESIGN.md`](firmware/webui/DESIGN.md)).

## Privacy

Neither project has accounts, analytics or servers of its own. Messages stay on your devices and on the mesh.
The iOS app's privacy policy is
[here](https://gist.github.com/Sewci0/c2a751f4ab9d0f8ca3b5b64f1100e24f).

## Support

Report problems and ask questions in [GitHub Issues](https://github.com/Sewci0/meshchat/issues). Please don't
include your node's position, keys or anything else personal: issues are public.

## Etiquette on the mesh

- **Send one flood advert after setup**, then only when your name changes. Every repeater in the region
  re-transmits it.
- **Use a test channel for tests**, not Public.
- **Public and hashtag channels are readable by anyone**, because their key comes from the name. Use a direct
  message or a private channel for anything personal.
- Antenna placement matters most: a window or an upstairs room gains more than any setting.

## Licence

[MIT](LICENSE). The firmware is MeshCore plus a patch: MeshCore's own code stays under MeshCore's MIT licence.
Third-party components keep their licences; the iOS app lists them under Settings → Acknowledgements.

## Not affiliated with MeshCore

MeshChat is an independent project, not affiliated with or endorsed by the MeshCore project.
