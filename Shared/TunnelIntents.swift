import AppIntents
import Foundation

/// Intents for controlling the connection from Shortcuts, Spotlight, Siri,
/// and (once the widget extension exists) Control Center. Each perform runs
/// headless in the intent process: it works purely against the persisted
/// profile set and the system's tunnel profile manager, never the app's
/// in-memory UI state.
@MainActor
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

/// Runs one script by name, the same way the Run Now button does.
///
/// The name is matched without regard to case, so a phrase a person speaks does
/// not have to reproduce the capitalisation they typed. The run is a manual one,
/// which is the trigger that goes ahead even for a script that is switched off:
/// asking for it directly is the whole point. Nothing here binds to a
/// controller's status changes, so no event script fires from this path.
struct RunScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Script"
    static let description = IntentDescription(
        "Runs one of the app's scripts by name, as if you had run it from the script list."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Script")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = await headlessController()
        let service = ScriptService.live(controller: controller)
        service.load()

        guard let script = service.scripts.first(where: { Self.matches($0.name, name) }) else {
            return .result(dialog: IntentDialog(stringLiteral: "No script named \(name)."))
        }
        guard let record = await service.run(script.id, trigger: .manual) else {
            return .result(dialog: IntentDialog(stringLiteral: "\(script.name) is already running."))
        }
        return .result(dialog: IntentDialog(stringLiteral: Self.dialog(for: record)))
    }

    private static func matches(_ candidate: String, _ name: String) -> Bool {
        candidate.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func dialog(for record: ScriptRunRecord) -> String {
        switch record.outcome {
        case .success:
            guard let output = record.output, !output.isEmpty else {
                return "\(record.scriptName) finished."
            }
            return "\(record.scriptName): \(output)"
        case .timeout:
            return "\(record.scriptName) ran out of time."
        case .error:
            return "\(record.scriptName) failed."
        case .skipped:
            return "\(record.scriptName) was stopped."
        }
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
        AppShortcut(
            intent: RunScriptIntent(),
            // The phrase names no parameter: a script name is free text, and the
            // metadata processor allows only an AppEntity or AppEnum in a phrase.
            // The system asks for the name when the phrase leaves it out.
            phrases: [
                "Run a script in \(.applicationName)",
                "Run my \(.applicationName) script",
            ],
            shortTitle: "Run Script",
            systemImageName: "curlybraces"
        )
    }
}
