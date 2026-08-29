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
                    let (packets, _) : ([Data], [NSNumber]) = await withCheckedContinuation { result in
                        self.flow.readPackets { data, protocols in
                            result.resume(returning: (data, protocols))
                        }
                    }
                    for packet in packets {
                        continuation.yield(packet)
                    }
                }
            }
        }
    }

    func writePackets(_ packets: [Data]) async {
        let protocols = packets.map { NSNumber(value: Self.protocolFamily(of: $0)) }
        flow.writePackets(packets, withProtocols: protocols)
    }

    static func protocolFamily(of packet: Data) -> sa_family_t {
        guard let first = packet.first else { return sa_family_t(AF_INET) }
        return (first >> 4) == 6 ? sa_family_t(AF_INET6) : sa_family_t(AF_INET)
    }
}
