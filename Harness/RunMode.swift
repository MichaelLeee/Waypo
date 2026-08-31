import Foundation

/// `--run` mode: full-tunnel study mode. Loads the app's configuration file,
/// brings up a real utun device, and hands it to the engine with
/// engine-managed routes. No NetworkExtension and no special entitlements are
/// involved; root is required because the engine rewrites the system routes.
func runTunnel(unit: Int32, address: String, peerAddress: String, configPath: String) async -> Int32 {
#if canImport(Libbox)
    guard let configData = FileManager.default.contents(atPath: configPath) else {
        FileHandle.standardError.write("configuration file not found: \(configPath)\n".data(using: .utf8)!)
        return 1
    }
    let configuration: TunnelConfiguration
    do {
        configuration = try JSONDecoder().decode(TunnelConfiguration.self, from: configData)
    } catch {
        FileHandle.standardError.write("cannot decode configuration: \(error)\n".data(using: .utf8)!)
        return 1
    }
    if configuration.servers.isEmpty {
        FileHandle.standardError.write("configuration has no servers\n".data(using: .utf8)!)
        return 1
    }

    do {
        let utun = try UtunInterface(unit: unit)
        print("created \(utun.name)")
        try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])

        let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)
        let engine = LibboxCoreEngine(tunFileDescriptor: utun.fileDescriptor, autoRoute: true)
        try await engine.start(configuration: configuration, packetFlow: flow)
        print("tunnel running on \(utun.name) via \(configuration.servers[0].name) — Ctrl+C to stop")
        installSignalHandlers(engine: engine)
        dispatchMain()
        return 0
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        return 1
    }
#else
    FileHandle.standardError.write("--run requires the packaged core library (build with Libbox.xcframework)\n".data(using: .utf8)!)
    return 1
#endif
}

#if canImport(Libbox)
/// Ctrl+C / SIGTERM must reach engine.stop() so the engine closes the
/// service and removes the routes it added; a bare kill would leave the
/// system routing table pointed at the dead utun device. The sources are
/// write-once from the main flow and only read by dispatch, so unsynchronized
/// access is safe here.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

private func installSignalHandlers(engine: LibboxCoreEngine) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for signalNumber in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler {
            print("\nstopping — restoring routes…")
            Task {
                await engine.stop()
                exit(0)
            }
        }
        source.resume()
        signalSources.append(source)
    }
}
#endif
