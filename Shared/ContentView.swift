import NetworkExtension
import SwiftUI

struct ContentView: View {
    @State private var controller = TunnelController()

    var body: some View {
        NavigationStack {
            List {
                Section("Tunnel") {
                    HStack {
                        Text(statusLabel)
                            .foregroundStyle(statusColor)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { controller.status == .connected || controller.status == .connecting },
                            set: { _ in Task { await controller.toggle() } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    if let error = controller.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Servers") {
                    ForEach(controller.configuration.servers, id: \.self) { server in
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text("\(server.host):\(server.port)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Waypo")
        }
        .task { await controller.refresh() }
    }

    private var statusLabel: String {
        switch controller.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Disconnected"
        case .invalid: "Profile not installed"
        case .reasserting: "Reasserting…"
        @unknown default: "Unknown"
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
