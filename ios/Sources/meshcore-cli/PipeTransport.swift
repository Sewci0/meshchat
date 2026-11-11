import Foundation
import MeshCoreKit

/// The radio's WiFi port through `/usr/bin/nc`, for testing on a Mac where this tool isn't allowed on the
/// local network (macOS Local Network privacy exempts Apple's own tools). Same byte stream and framing as
/// `TCPTransport`; only the socket differs.
final class PipeTransport: MeshTransport, @unchecked Sendable {
    let host: String, port: UInt16
    let frames: AsyncThrowingStream<Data, Error>
    var label: String { "WiFi via nc: \(host)" }

    private let sink: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var framing = StreamFraming()

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        (frames, sink) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    func connect() async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [host, String(port)]
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [sink] _ in sink.finish() }
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { return }
            let frames = self.lock.withLock { self.framing.feed(d) }
            for f in frames { self.sink.yield(f) }
        }
        try process.run()
        try await Task.sleep(for: .milliseconds(300))   // nc connects
        guard process.isRunning else { throw TransportError.connectFailed("nc exited") }
    }

    func send(_ frame: Data) async throws {
        try input.fileHandleForWriting.write(contentsOf: StreamFraming.wrap(frame))
    }

    func disconnect() {
        if process.isRunning { process.terminate() }
    }
}
