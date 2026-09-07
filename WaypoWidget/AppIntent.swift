import AppIntents
import Foundation

/// Runs inside the widget or control process and drives the shared profile
/// manager through TunnelController, so the button works without opening
/// the app.
struct ToggleTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Tunnel"
    static let description = IntentDescription("Connects or disconnects the tunnel.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = TunnelController()
        await controller.refresh()
        let wasActive = controller.isActive
        await controller.toggle()
        return .result(dialog: wasActive ? IntentDialog("Disconnecting") : IntentDialog("Connecting"))
    }
}

/// Control Center toggles pass the desired state through `value` rather
/// than toggling, so the intent brings the tunnel to that state.
struct SetTunnelStateIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Tunnel"
    static let openAppWhenRun = false

    @Parameter(title: "On")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = TunnelController()
        await controller.refresh()
        if controller.isActive != value {
            await controller.toggle()
        }
        return .result()
    }
}
