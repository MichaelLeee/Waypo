import Foundation
import NetworkExtension

/// Abstraction over the packet source so the engine can run inside the
/// NetworkExtension process (production) or against a utun device in the
/// development harness — the engine must not know which one it is on.
protocol PacketFlow: AnyObject, Sendable {
    func readPackets() -> AsyncStream<Data>
    func writePackets(_ packets: [Data]) async
}

final class NetworkExtensionPacketFlow: PacketFlow, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func readPackets() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                while true {
                    let packets: [NEPacket] = await withCheckedContinuation { result in
                        self.flow.readPackets { result.resume(returning: $0) }
                    }
                    for packet in packets {
                        continuation.yield(packet.data)
                    }
                }
            }
        }
    }

    func writePackets(_ packets: [Data]) async {
        flow.writePackets(packets.map { NEPacket(data: $0, protocolFamily: Self.protocolFamily(of: $0)) })
    }

    static func protocolFamily(of packet: Data) -> UInt32 {
        guard let first = packet.first else { return UInt32(AF_INET) }
        return (first >> 4) == 6 ? UInt32(AF_INET6) : UInt32(AF_INET)
    }
}
