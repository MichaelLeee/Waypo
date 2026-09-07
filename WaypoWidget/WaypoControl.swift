#if os(iOS)
import NetworkExtension
import SwiftUI
import WidgetKit

/// Control Center toggle for the tunnel. The initial state comes from the
/// shared status mirror; the system keeps the visual state after the intent
/// runs.
struct WaypoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "WaypoTunnelControl") {
            ControlWidgetToggle(
                "Tunnel",
                isOn: currentControlState,
                action: ToggleTunnelIntent()
            ) { isOn in
                Label("Tunnel", systemImage: isOn ? "shield.fill" : "shield")
            }
        }
        .displayName("Tunnel")
    }

    private var currentControlState: Bool {
        TunnelStore().loadStatusMirror().flatMap(NEVPNStatus.init(rawValue:)) == .connected
    }
}
#endif
