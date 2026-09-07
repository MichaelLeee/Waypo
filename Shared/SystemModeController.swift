#if os(macOS)
import AppKit
import Foundation
import Observation

#if canImport(Libbox)
import Libbox
#endif

/// macOS system-wide mode: the engine runs in-process with a loopback mixed
/// inbound, and the system network configuration (web, secure web, SOCKS) is
/// pointed at it through a single privileged command. Needs no profile
/// install, so it works on free developer teams and is the full end-to-end
/// test path alongside the harness.
@MainActor
@Observable
final class SystemModeController {
    static let listenerPort = 7219

    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var traffic: CoreStats?

    private var configuredServices: [String] = []

#if canImport(Libbox)
    private var engine: LibboxCoreEngine?
    private var statsTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
#endif

    func toggle(configuration: TunnelConfiguration) {
        Task { await toggleStart(configuration: configuration) }
    }

    func toggleStart(configuration: TunnelConfiguration) async {
        if isRunning {
            await stop()
        } else {
            await start(configuration: configuration)
        }
    }

    func start(configuration: TunnelConfiguration) async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
#if canImport(Libbox)
        let newEngine = LibboxCoreEngine(listenerPort: Self.listenerPort)
        do {
            try await newEngine.start(configuration: configuration, packetFlow: UnavailablePacketFlow())
        } catch {
            lastError = error.localizedDescription
            return
        }
        // The engine is live; point the system at it. If the user declines
        // the authorization prompt, roll the engine back so nothing is left
        // half-configured.
        do {
            configuredServices = try applySystemConfiguration()
        } catch {
            await newEngine.stop()
            lastError = error.localizedDescription
            return
        }
        engine = newEngine
        isRunning = true
        monitorEngine(newEngine)
#else
        lastError = "The packaged engine library is not available in this build."
#endif
    }

    func stop() async {
        guard isRunning else { return }
        // Settings come first: once the engine is gone nothing is listening,
        // and leaving them applied would black-hole system traffic.
        do {
            try clearSystemConfiguration()
        } catch {
            lastError = error.localizedDescription
        }
#if canImport(Libbox)
        statsTask?.cancel()
        statsTask = nil
        eventTask?.cancel()
        eventTask = nil
        await engine?.stop()
        engine = nil
        traffic = nil
#endif
        isRunning = false
    }

#if canImport(Libbox)
    private func monitorEngine(_ engine: LibboxCoreEngine) {
        statsTask = Task { [weak self] in
            for await stats in engine.stats() {
                self?.traffic = stats
            }
        }
        eventTask = Task { [weak self] in
            for await event in engine.events() {
                if case .stopped = event {
                    await self?.handleUnexpectedStop()
                }
            }
        }
    }

    /// The engine stopped without user action; revert the system network
    /// configuration so apps are not left pointed at a dead listener.
    private func handleUnexpectedStop() async {
        guard isRunning else { return }
        do {
            try clearSystemConfiguration()
        } catch {
            lastError = error.localizedDescription
        }
        statsTask?.cancel()
        statsTask = nil
        eventTask?.cancel()
        eventTask = nil
        await engine?.stop()
        engine = nil
        traffic = nil
        isRunning = false
    }

    /// Satisfies the CoreEngine contract, which always takes a packet flow;
    /// system-wide mode has no tun device to feed.
    private final class UnavailablePacketFlow: PacketFlow, @unchecked Sendable {
        func readPackets() -> AsyncStream<Data> { AsyncStream { $0.finish() } }
        func writePackets(_ packets: [Data]) async {}
    }
#endif

    // MARK: - System network configuration

    private func applySystemConfiguration() throws -> [String] {
        let services = networkServices()
        guard !services.isEmpty else {
            throw SystemModeError("No network services found to configure.")
        }
        var commands: [String] = []
        for service in services {
            let name = shellQuoted(service)
            commands.append("networksetup -setwebproxy \(name) 127.0.0.1 \(Self.listenerPort)")
            commands.append("networksetup -setsecurewebproxy \(name) 127.0.0.1 \(Self.listenerPort)")
            commands.append("networksetup -setsocksfirewallproxy \(name) 127.0.0.1 \(Self.listenerPort)")
        }
        try runPrivileged(commands.joined(separator: " && "))
        return services
    }

    private func clearSystemConfiguration() throws {
        guard !configuredServices.isEmpty else { return }
        var commands: [String] = []
        for service in configuredServices {
            let name = shellQuoted(service)
            commands.append("networksetup -setwebproxystate \(name) off")
            commands.append("networksetup -setsecurewebproxystate \(name) off")
            commands.append("networksetup -setsocksfirewallproxy \(name) off")
        }
        try runPrivileged(commands.joined(separator: " && "))
        configuredServices = []
    }

    private func networkServices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .dropFirst() // header line
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// Runs a shell command after asking the user for administrator approval.
    private func runPrivileged(_ command: String) throws {
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw SystemModeError(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemModeError(message.isEmpty ? "The privileged command failed." : message)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct SystemModeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif
