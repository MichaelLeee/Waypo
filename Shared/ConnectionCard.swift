import NetworkExtension
import SwiftUI

/// Compact status row for list contexts (iOS).
struct ConnectionStatusRow: View {
    var controller: TunnelController

    private var style: ConnectionStatusStyle {
        ConnectionStatusStyle(controller.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                Text(style.label)
                    .foregroundStyle(style.color)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.isActive },
                    set: { _ in Task { await controller.toggle() } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(controller.status == .disconnecting)
                .accessibilityLabel(controller.isActive ? "Stop" : "Start")
            }
            if let traffic = controller.traffic {
                Text(caption(for: traffic))
                    .font(.caption2)
                    .foregroundStyle(Palette.neutral)
                    .contentTransition(.numericText())
                    .animation(.default, value: traffic.bytesIn)
            }
            if controller.status == .connected {
                Toggle("Connect On Demand", isOn: Binding(
                    get: { controller.isOnDemandEnabled },
                    set: { enabled in Task { await controller.setOnDemand(enabled) } }
                ))
                .font(.caption)
            }
        }
    }

    private func caption(for traffic: CoreStats) -> String {
        var parts = ["\(byteCount(traffic.bytesOut)) up", "\(byteCount(traffic.bytesIn)) down", "\(traffic.activeConnections) active"]
        if let uptime = controller.uptimeLabel {
            parts.append(uptime)
        }
        return parts.joined(separator: " · ")
    }
}

private func byteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}

/// Signature connection control for the macOS detail pane.
struct ConnectionCard: View {
    var controller: TunnelController

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Metrics.heroIconSize
    @ScaledMetric(relativeTo: .title) private var actionSize = Metrics.actionIconSize
    @ScaledMetric(relativeTo: .title) private var buttonSize = Metrics.actionButtonSize

    private var style: ConnectionStatusStyle {
        ConnectionStatusStyle(controller.status)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: style.symbol)
                .font(.system(size: heroSize))
                .foregroundStyle(style.color)
                .contentTransition(.symbolEffect(.replace))

            Text(style.label)
                .font(.title2.weight(.medium))

            if let server = controller.configuration.servers.first {
                Text("\(server.name) — \(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }

            if controller.status == .connected, let traffic = controller.traffic {
                HStack(spacing: 16) {
                    Label(byteCount(traffic.bytesOut), systemImage: "arrow.up")
                    Label(byteCount(traffic.bytesIn), systemImage: "arrow.down")
                    Label("\(traffic.activeConnections)", systemImage: "link")
                    if let uptime = controller.uptimeLabel {
                        Label(uptime, systemImage: "clock")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(Palette.neutral)
                .contentTransition(.numericText())
            }

            Toggle("Connect On Demand", isOn: Binding(
                get: { controller.isOnDemandEnabled },
                set: { enabled in Task { await controller.setOnDemand(enabled) } }
            ))
            .disabled(controller.status == .invalid)

            Button(action: { Task { await controller.toggle() } }) {
                Image(systemName: controller.isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: actionSize))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(in: Circle())
            .disabled(controller.status == .disconnecting)
            .accessibilityLabel(controller.isActive ? "Stop" : "Start")

            if let error = controller.lastError {
                ErrorText(error)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: controller.status)
    }
}
