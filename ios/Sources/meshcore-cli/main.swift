// meshcore-cli: checks a MeshCore radio from a Mac with the same code the iOS app uses. Read-only: it
// asks the radio about itself, its contacts and channels, then prints what it hears. It never transmits.
//
//   swift run meshcore-cli tcp <host> [port] [--listen seconds]
//   swift run meshcore-cli nc <host> [port] [--listen seconds]   (the same, through /usr/bin/nc)
//   swift run meshcore-cli scan
//   swift run meshcore-cli ble <name or identifier> [--listen seconds]
import Foundation
import MeshCoreKit

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let listenSeconds = Double(option("--listen") ?? "20") ?? 20

func usage() -> Never {
    print("usage: meshcore-cli tcp <host> [port] [--listen s] | scan | ble <name|uuid> [--listen s]")
    exit(2)
}

func log(_ s: String) { print(s); fflush(stdout) }

func scan(seconds: Double) async -> [DiscoveredRadio] {
    let scanner = BluetoothScanner()
    let task = Task { () -> [DiscoveredRadio] in
        var found: [UUID: DiscoveredRadio] = [:]
        for await r in scanner.radios where found[r.id] == nil {
            found[r.id] = r
            log("  \(r.name)  \(r.rssi) dBm  \(r.id)")
        }
        return Array(found.values)
    }
    try? await Task.sleep(for: .seconds(seconds))
    scanner.stop()   // ends the stream, so the task returns what it found
    return await task.value
}

func transport() async -> MeshTransport {
    guard let mode = args.first else { usage() }
    switch mode {
    case "tcp":
        guard args.count >= 2 else { usage() }
        let port = args.count >= 3 ? UInt16(args[2]) : nil
        return TCPTransport(host: args[1], port: port ?? 5000)
    case "nc":
        guard args.count >= 2 else { usage() }
        let port = args.count >= 3 ? UInt16(args[2]) : nil
        return PipeTransport(host: args[1], port: port ?? 5000)
    case "ble":
        guard args.count >= 2 else { usage() }
        let want = args[1]
        if let id = UUID(uuidString: want) { return BluetoothTransport(identifier: id) }
        log("scanning for \(want)…")
        let radios = await scan(seconds: 6)
        guard let r = radios.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else { log("not found"); exit(1) }
        return BluetoothTransport(identifier: r.id, name: r.name)
    case "scan":
        log("Bluetooth radios nearby (8 s):")
        _ = await scan(seconds: 8)
        exit(0)
    default: usage()
    }
}

let link = await transport()
let client = MeshCoreClient(transport: link)
log("connecting (\(link.label))…")
let started = Date()
do {
    let (device, me) = try await client.start(appName: "meshcore-cli")
    log(String(format: "connected in %.2f s", Date().timeIntervalSince(started)))
    log("radio:    \(device.model), firmware \(device.version) (\(device.buildDate)), protocol \(device.firmwareCode)")
    log("limits:   \(device.maxContacts) contacts, \(device.maxChannels) channels, repeat \(device.repeatEnabled.map { $0 ? "on" : "off" } ?? "?"), path hash mode \(device.pathHashMode.map(String.init) ?? "?")")
    log("me:       \(me.name)  \(me.key.hex.prefix(16))…  TX \(me.txPower)/\(me.maxTxPower) dBm")
    log(String(format: "network:  %.3f MHz, %g kHz, SF%d, CR%d", me.radio.frequencyMHz, me.radio.bandwidthKHz, me.radio.spreadingFactor, me.radio.codingRate))
    if let t = try? await client.time() { log("clock:    \(Date(timeIntervalSince1970: TimeInterval(t)))") }
    if let b = try? await client.battery() { log("battery:  \(b.millivolts) mV, storage \(b.storageUsedKB)/\(b.storageTotalKB) KB") }

    let t0 = Date()
    let (contacts, lastMod) = try await client.contacts()
    log(String(format: "contacts: %d in %.1f s (newest change %u)", contacts.count, Date().timeIntervalSince(t0), lastMod))
    let byType = Dictionary(grouping: contacts, by: \.type).mapValues(\.count)
    log("          " + NodeType.allCases.compactMap { t in byType[t].map { "\(t): \($0)" } }.joined(separator: ", "))
    let routed = contacts.filter { $0.outPath != nil }
    log("          \(routed.count) with a saved route" + (routed.first.map { c in ", e.g. \(c.name): " + c.outPath!.hops.map(\.hex).joined(separator: " → ") } ?? ""))

    let channels = try await client.channels()
    log("channels: " + channels.map { "\($0.index) \($0.name) [\(String(format: "%02x", $0.hash))]" }.joined(separator: ", "))

    // what it hears, decoded: channel messages decrypted with the joined channels' keys
    log("listening for \(Int(listenSeconds)) s (read-only)…")
    let keys = channels.map { ($0.name, $0.secret) }
    let names = Dictionary(contacts.map { ($0.key.prefix(1).hex, $0.name) }, uniquingKeysWith: { a, _ in a })
    let listen = Task {
        for await e in client.events {
            switch e {
            case .rxLog(let entry):
                guard let p = entry.packet else { log("  rx  (unparsed \(entry.raw.count) B)"); continue }
                var line = String(format: "  rx  %@ %@ hops %d  SNR %.2f  RSSI %d  fp %08x", p.payloadType.name, "\(p.route)", p.hops, entry.snr, entry.rssi, p.fingerprint)
                if !p.path.isEmpty { line += "  via " + p.path.map { names[$0.prefix(1).hex].map { n in "\(n)" } ?? $0.hex }.joined(separator: " → ") }
                if p.payloadType == .groupText {
                    if let (name, plain) = keys.lazy.compactMap({ k in ChannelCrypto.decryptGroupText(p.payload, key: k.1).map { (k.0, $0) } }).first {
                        line += "\n        \(name): \(plain.text)"
                    } else {
                        line += String(format: "\n        (channel %02x, not joined)", p.payload.first ?? 0)
                    }
                }
                if let a = p.advert { line += "\n        advert: \(a.type) \(a.name)" + (a.position.map { String(format: " at %.4f, %.4f", $0.latitude, $0.longitude) } ?? "") }
                log(line)
            case .messagesWaiting: log("  messages waiting (left for the phone apps)")
            case .messageForAnotherApp(let m): log("  another app fetched: \(m)")
            case .advert(let k): log("  advert from contact \(k)")
            case .pathUpdated(let k): log("  route updated: \(k)")
            case .disconnected(let why): log("  disconnected \(why ?? "")"); return
            default: log("  event: \(e)")
            }
        }
    }
    try await Task.sleep(for: .seconds(listenSeconds))
    listen.cancel()
    await client.stop()
    log("done")
} catch {
    log("failed: \(error)")
    exit(1)
}
