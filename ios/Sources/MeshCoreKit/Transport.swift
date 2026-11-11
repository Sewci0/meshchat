import Foundation
import Network

/// A link to a radio that carries whole companion frames.
public protocol MeshTransport: AnyObject, Sendable {
    /// Frames from the radio, one each, then the end of the connection (finished with an error if it failed).
    var frames: AsyncThrowingStream<Data, Error> { get }
    func connect() async throws
    func send(_ frame: Data) async throws
    func disconnect()
    /// For the UI: "Bluetooth: MeshCore-ab12", "WiFi: 192.168.1.50".
    var label: String { get }
}

public enum TransportError: Error, Sendable, CustomStringConvertible {
    case notConnected
    case connectFailed(String)
    case bluetoothUnavailable(String)
    case notFound

    public var description: String {
        switch self {
        case .notConnected: String(localized: "Not connected to the radio.")
        case .connectFailed(let why): String(localized: "Couldn't connect: \(why)")
        case .bluetoothUnavailable(let why): why
        case .notFound: String(localized: "The radio wasn't found.")
        }
    }
}

/// A radio's WiFi companion port (TCP 5000 by default). Frames are `>` + length (2 bytes LE) + frame
/// from the radio, `<` + length + frame to it. The radio serves one TCP client at a time: connecting
/// drops the previous one.
/// The WiFi (TCP) framing: `>` + length (2 bytes LE) + frame from the radio, `<` + length + frame to
/// it. Shared by `TCPTransport` and anything else that carries the same byte stream.
public struct StreamFraming: Sendable {
    private var buffer = Data()
    public init() {}

    /// Feeds bytes in; returns the whole frames now complete (stray bytes before a `>` are skipped).
    public mutating func feed(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var out: [Data] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x3E) else { buffer.removeAll(); break }   // '>'
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            guard buffer.count >= 3 else { break }
            let b = buffer.startIndex
            let length = Int(buffer[b + 1]) | Int(buffer[b + 2]) << 8
            guard buffer.count >= 3 + length else { break }
            out.append(buffer.subdata(in: b + 3..<b + 3 + length))
            buffer.removeSubrange(b..<b + 3 + length)
        }
        return out
    }

    /// A frame to the radio, wrapped for the stream.
    public static func wrap(_ frame: Data) -> Data {
        var packet = Data([0x3C, UInt8(frame.count & 0xFF), UInt8(frame.count >> 8)])   // '<'
        packet.append(frame)
        return packet
    }
}

/// True the first time only: for resuming a continuation from callbacks that may repeat.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

public final class TCPTransport: MeshTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let frames: AsyncThrowingStream<Data, Error>
    public var label: String { String(localized: "WiFi: \(host)") }

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let queue = DispatchQueue(label: "meshcore.tcp")
    private var connection: NWConnection?
    private var framing = StreamFraming()   // touched only on `queue`

    public init(host: String, port: UInt16 = 5000) {
        self.host = host
        self.port = port
        (frames, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public func connect() async throws {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.connectionTimeout = 10
        options.enableKeepalive = true
        options.keepaliveIdle = 30
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: options))
        connection = c
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                    self?.receive()
                case .failed(let e), .waiting(let e):
                    if once.claim() { cont.resume(throwing: TransportError.connectFailed(e.localizedDescription)); c.cancel() }
                    else { self?.continuation.finish(throwing: e) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: TransportError.notConnected) }
                    self?.continuation.finish()
                default: break
                }
            }
            c.start(queue: queue)
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { for f in self.framing.feed(data) { self.continuation.yield(f) } }
            if let error { self.continuation.finish(throwing: error); return }
            if complete { self.continuation.finish(); return }
            self.receive()
        }
    }

    public func send(_ frame: Data) async throws {
        guard let c = connection, c.state == .ready else { throw TransportError.notConnected }
        let packet = StreamFraming.wrap(frame)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: packet, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
