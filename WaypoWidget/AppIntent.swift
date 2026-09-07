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
