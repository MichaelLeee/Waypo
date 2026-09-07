import AppIntents
import Foundation

/// Intents for controlling the connection from Shortcuts, Spotlight, Siri,
/// and (once the widget extension exists) Control Center. Each perform runs
/// headless in the intent process: it works purely against the persisted
/// profile set and the system's tunnel profile manager, never the app's
/// in-memory UI state.
private func headlessController() async -> TunnelController {
    let controller = TunnelController()
    await controller.refresh()
    return controller
}

struct ToggleConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Connection"
    static let description = IntentDescription(
        "Starts the tunnel if it is stopped; stops it if it is running."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = await headlessController()
        let wasActive = controller.isActive
        await controller.toggle()
        // The start/stop request is asynchronous; report the requested
        // action rather than the eventual status transition.
        return .result(dialog: wasActive ? IntentDialog("Stopping") : IntentDialog("Connecting"))
    }
}

struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect"
    static let description = IntentDescription("Starts the tunnel. No-op if it is already running.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = await headlessController()
        if controller.isActive {
            return .result(dialog: IntentDialog("Already connected"))
        }
        await controller.toggle()
        return .result(dialog: IntentDialog("Connecting"))
    }
}

struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let description = IntentDescription("Stops the tunnel. No-op if it is not running.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = await headlessController()
        if !controller.isActive {
            return .result(dialog: IntentDialog("Already disconnected"))
        }
        await controller.toggle()
        return .result(dialog: IntentDialog("Disconnecting"))
    }
}

/// Exposes the intents to Siri phrases and the system search without
/// needing a shortcut to be created first.
struct WaypoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleConnectionIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "Toggle connection in \(.applicationName)",
            ],
            shortTitle: "Toggle Connection",
            systemImageName: "arrow.up.arrow.down"
        )
        AppShortcut(
            intent: ConnectIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Connect",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: DisconnectIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Disconnect",
            systemImageName: "stop.circle"
        )
    }
}
