import Foundation
import Network

/// Measures TCP handshake latency against a server endpoint.
enum ServerLatency {
    /// Resumes the continuation exactly once across the racing
    /// state-update and timeout paths.
    private final class Finisher: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let handler: (Double?) -> Void

        init(_ handler: @escaping (Double?) -> Void) {
            self.handler = handler
        }

        @discardableResult
        func finish(_ value: Double?) -> Bool {
            lock.lock()
            guard !finished else { lock.unlock(); return false }
            finished = true
            lock.unlock()
            handler(value)
            return true
        }
    }

    /// Returns the handshake time in milliseconds, or nil on failure/timeout.
    static func measure(host: String, port: Int, timeout: TimeInterval = 5) async -> Double? {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), endpointPort != .any else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let finisher = Finisher { continuation.resume(returning: $0) }
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            nonisolated(unsafe) let connectionForHandler = connection
            let start = DispatchTime.now()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    if finisher.finish(elapsed) {
                        connectionForHandler.cancel()
                    }
                case .failed:
                    finisher.finish(nil)
                    connectionForHandler.cancel()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if finisher.finish(nil) {
                    connection.cancel()
                }
            }
        }
    }
}
