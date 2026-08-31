import NetworkExtension
import SwiftUI

/// Compact status row for list contexts (iOS).
struct ConnectionStatusRow: View {
    var controller: TunnelController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(controller.statusLabel)
                    .foregroundStyle(statusColor)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.isActive },
                    set: { _ in Task { await controller.toggle() } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(controller.status == .disconnecting)
            }
            if let traffic = controller.traffic {
                Text("\(byteCount(traffic.bytesOut)) up · \(byteCount(traffic.bytesIn)) down · \(traffic.activeConnections) active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .connected: .green
        case .connecting, .reasserting: .orange
        default: .secondary
        }
    }
}

private func byteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}

/// Signature connection control for the macOS detail pane.
struct ConnectionCard: View {
    var controller: TunnelController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: controller.status == .connected ? "point.3.connected.trianglepath.dotted" : "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 40))
                .foregroundStyle(controller.status == .connected ? Color.green : Color.secondary)

            Text(controller.statusLabel)
                .font(.title2.weight(.medium))

            if let server = controller.configuration.servers.first {
                Text("\(server.name) — \(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if controller.status == .connected, let traffic = controller.traffic {
                HStack(spacing: 16) {
                    Label(byteCount(traffic.bytesOut), systemImage: "arrow.up")
                    Label(byteCount(traffic.bytesIn), systemImage: "arrow.down")
                    Label("\(traffic.activeConnections)", systemImage: "link")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button(action: { Task { await controller.toggle() } }) {
                Image(systemName: controller.isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 28))
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .glassEffect(in: Circle())
            .disabled(controller.status == .disconnecting)

            if let error = controller.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
