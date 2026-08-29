import Darwin
import Foundation

/// utun-backed PacketFlow for the harness. utun frames carry a 4-byte
/// address-family header in native byte order — stripped on read, prepended
/// on write.
final class UtunPacketFlow: PacketFlow, @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.utun")

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func readPackets() -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: self.fileDescriptor, queue: self.queue)
            source.setEventHandler { [fileDescriptor] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                let count = read(fileDescriptor, &buffer, buffer.count)
                guard count > 4 else { return }
                continuation.yield(Data(buffer.prefix(count).dropFirst(4)))
            }
            source.setCancelHandler {}
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }

    func writePackets(_ packets: [Data]) async {
        for packet in packets {
            guard let first = packet.first else { continue }
            let family: UInt32 = (first >> 4) == 6 ? UInt32(AF_INET6) : UInt32(AF_INET)
            var framed = Data(count: 4)
            withUnsafeBytes(of: family) { framed.replaceSubrange(0..<4, with: $0) }
            framed.append(packet)
            let written = framed.withUnsafeBytes { buffer in
                write(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard written == framed.count else { return }
        }
    }
}
