@preconcurrency import CoreBluetooth
import Foundation

/// MeshCore radios over Bluetooth LE: the Nordic UART service. Each write to RX is one frame to the radio,
/// each notification on TX one frame from it. Pairing (the radio's PIN) is iOS's own prompt, the first time
/// an encrypted characteristic is used.
public enum MeshCoreBLE {
    public static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// app → radio (write)
    public static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// radio → app (notify)
    public static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
}

/// A radio found by a Bluetooth scan.
public struct DiscoveredRadio: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
}

/// Whether Bluetooth can be used right now.
public enum BluetoothAvailability: Sendable, Equatable {
    case starting, on, off, notAllowed, unsupported
}

/// Lists nearby MeshCore radios (anything advertising the Nordic UART service).
public final class BluetoothScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public let radios: AsyncStream<DiscoveredRadio>
    private let continuation: AsyncStream<DiscoveredRadio>.Continuation
    /// Bluetooth's state as it changes (off, not allowed, unavailable here, on).
    public let availability: AsyncStream<BluetoothAvailability>
    private let availabilitySink: AsyncStream<BluetoothAvailability>.Continuation
    private let queue = DispatchQueue(label: "meshcore.ble.scan")
    private var central: CBCentralManager!

    public override init() {
        (radios, continuation) = AsyncStream.makeStream(of: DiscoveredRadio.self)
        (availability, availabilitySink) = AsyncStream.makeStream(of: BluetoothAvailability.self, bufferingPolicy: .bufferingNewest(1))
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func stop() {
        queue.async { [self] in
            if central.state == .poweredOn { central.stopScan() }
            continuation.finish()
            availabilitySink.finish()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            availabilitySink.yield(.on)
            central.scanForPeripherals(withServices: [MeshCoreBLE.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff: availabilitySink.yield(.off)
        case .unauthorized: availabilitySink.yield(.notAllowed)
        case .unsupported: availabilitySink.yield(.unsupported)
        default: availabilitySink.yield(.starting)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? String(localized: "MeshCore radio")
        continuation.yield(DiscoveredRadio(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }
}

/// A connection to one radio, by the identifier a scan found (iOS remembers it across launches).
public final class BluetoothTransport: NSObject, MeshTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public let identifier: UUID
    public let frames: AsyncThrowingStream<Data, Error>
    public private(set) var label: String

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let queue = DispatchQueue(label: "meshcore.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    // pending callbacks, each touched only on `queue`
    private var poweredOn: CheckedContinuation<Void, Error>?
    private var connected: CheckedContinuation<Void, Error>?
    private var written: CheckedContinuation<Void, Error>?

    public init(identifier: UUID, name: String = String(localized: "MeshCore radio")) {
        self.identifier = identifier
        label = String(localized: "Bluetooth: \(name)")
        (frames, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
        #if os(iOS)
        // the system relaunches the app for Bluetooth events after it was suspended
        let options: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: "meshchat.radio"]
        #else
        let options: [String: Any] = [:]
        #endif
        central = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if central.state == .poweredOn { c.resume() } else { poweredOn = c }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                    c.resume(throwing: TransportError.notFound); return
                }
                peripheral = p
                p.delegate = self
                connected = c
                central.connect(p, options: nil)
            }
        }
    }

    public func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let p = peripheral, let rx = rxChar, p.state == .connected else {
                    c.resume(throwing: TransportError.notConnected); return
                }
                written = c
                p.writeValue(frame, for: rx, type: .withResponse)
            }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            if let p = peripheral { central.cancelPeripheralConnection(p) }
        }
    }

    // MARK: CBCentralManagerDelegate (on `queue`)

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOn?.resume(); poweredOn = nil
        case .unauthorized:
            fail(TransportError.bluetoothUnavailable(String(localized: "MeshChat isn't allowed to use Bluetooth. Turn it on in Settings → MeshChat.")))
        case .poweredOff:
            fail(TransportError.bluetoothUnavailable(String(localized: "Bluetooth is off.")))
        case .unsupported:
            fail(TransportError.bluetoothUnavailable(String(localized: "This device has no Bluetooth LE.")))
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == identifier }) {
            peripheral = p
            p.delegate = self
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let n = peripheral.name { label = String(localized: "Bluetooth: \(n)") }
        peripheral.discoverServices([MeshCoreBLE.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(TransportError.connectFailed(error?.localizedDescription ?? String(localized: "the radio didn't accept the connection", comment: "After \"Couldn't connect: \"")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxChar = nil
        if let e = error { fail(e) } else { continuation.finish() }
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == MeshCoreBLE.service }) else {
            fail(TransportError.connectFailed(String(localized: "not a MeshCore radio (no UART service)", comment: "After \"Couldn't connect: \""))); return
        }
        peripheral.discoverCharacteristics([MeshCoreBLE.rx, MeshCoreBLE.tx], for: s)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        guard let rx = chars.first(where: { $0.uuid == MeshCoreBLE.rx }), let tx = chars.first(where: { $0.uuid == MeshCoreBLE.tx }) else {
            fail(TransportError.connectFailed(String(localized: "the radio's UART service is incomplete", comment: "After \"Couldn't connect: \""))); return
        }
        rxChar = rx
        peripheral.setNotifyValue(true, for: tx)   // encrypted: this is where iOS asks for the PIN
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail(TransportError.connectFailed(error.localizedDescription)); return }
        connected?.resume(); connected = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == MeshCoreBLE.tx, let v = characteristic.value, !v.isEmpty { continuation.yield(v) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { written?.resume(throwing: error) } else { written?.resume() }
        written = nil
    }

    private func fail(_ e: Error) {
        poweredOn?.resume(throwing: e); poweredOn = nil
        connected?.resume(throwing: e); connected = nil
        written?.resume(throwing: e); written = nil
        continuation.finish(throwing: e)
    }
}
