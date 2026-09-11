import SwiftUI

/// Live list of the connections the engine is tracking while the tunnel is
/// up. Newest first; swipe to close one.
struct ConnectionsView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if controller.connections.isEmpty {
                    WaypoEmptyState(
                        "No Connections",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        message: controller.isActive
                            ? "Connections made through the tunnel appear here."
                            : "Connect the tunnel to see live connections."
                    )
                } else {
                    connectionsList
                }
            }
            .navigationTitle("Connections")
            .inlineTitleOnIOS()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionsList: some View {
        List {
            ForEach(controller.connections) { connection in
                ConnectionRow(connection: connection)
#if os(iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            controller.closeConnection(connection.id)
                        } label: {
                            Label("Close", systemImage: "xmark.circle")
                        }
                    }
#else
                    .contextMenu {
                        Button("Close Connection", role: .destructive) {
                            controller.closeConnection(connection.id)
                        }
                    }
#endif
            }
        }
    }
}

private struct ConnectionRow: View {
    var connection: EngineConnection

    var body: some View {
        HStack {
            Image(systemName: networkIcon)
                .foregroundStyle(Palette.neutral)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.domain ?? connection.destination)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(connection.network.uppercased())
                    if let rule = connection.rule {
                        Text(rule)
                    }
                    Text(connection.outbound)
                }
                .font(.caption2)
                .foregroundStyle(Palette.neutral)
                .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ \(byteCount(connection.upload))")
                Text("↓ \(byteCount(connection.download))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Palette.neutral)
            .contentTransition(.numericText())
            .animation(.default, value: connection.upload)
        }
    }

    private var networkIcon: String {
        switch connection.network {
        case "tcp": "network"
        case "udp": "waveform.path.ecg"
        default: "network"
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
