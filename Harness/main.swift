import Foundation

let usage = """
WaypoHarness — drives the tunnel engine in-process against a real utun device.
No NetworkExtension involved; needs root for utun creation.

Usage: sudo WaypoHarness [--self-test | --run PATH | --footprint] [--unit N]
                         [--address A.B.C.D] [--config PATH] [--limit-mb N]
                         [--require-engine]

  --self-test       run the data-path self-test (UDP round trip through the
                    engine) and exit 0 on success, 1 on failure
  --run PATH        run the tunnel with the configuration JSON at PATH
                    (the app writes one to Application Support/Waypo on
                    every save). The engine manages system routes, so all
                    traffic flows through the configured server until
                    Ctrl+C.
  --footprint       start the engine, push a little traffic through it, and
                    report this process's memory at each phase as
                    FOOTPRINT lines. Exits non-zero only with
                    --require-engine and an over-budget reading, so a
                    measurement never reds a build on its own.
  --config PATH     configuration for --footprint. Defaults to the mirror the
                    app writes; when neither exists a synthetic direct
                    configuration is used, which is what CI measures.
  --limit-mb N      budget for --footprint in megabytes (default 50).
  --require-engine  make --footprint exit 1 when the peak exceeds the budget.
  --unit N          utun unit number (default 9, device becomes utun9)
  --address A.B.C.D local IPv4 address on the utun device (default 198.18.0.1)
"""

var unit: Int32 = 9
var address = "198.18.0.1"
// The peer address is the test destination. A point-to-point peer gets a
// kernel host route through the device, which is what pushes interface-pinned
// datagrams onto the file descriptor. The engine dials the on-host echo
// server at loopback via a route-rule address override, so the peer address
// is never dialed and may live inside the device's own subnet; see SelfTest
// and the engine configuration.
let peerAddress = "198.18.0.2"
var defaultRoute = false
var selfTest = false
var runConfigPath: String?
var footprint = false
var footprintLimitBytes = MemoryFootprint.extensionBudgetBytes
var footprintConfigPath: String?
var requireEngine = false

let rawArgs = Array(ProcessInfo.processInfo.arguments.dropFirst())
var index = 0
while index < rawArgs.count {
    let arg = rawArgs[index]
    switch arg {
    case "--unit":
        index += 1
        guard index < rawArgs.count, let parsed = Int32(rawArgs[index]) else {
            print("missing or invalid value for --unit\n\(usage)")
            exit(2)
        }
        unit = parsed
    case "--address":
        index += 1
        guard index < rawArgs.count else {
            print("missing value for --address\n\(usage)")
            exit(2)
        }
        address = rawArgs[index]
    case "--default-route":
        defaultRoute = true
    case "--self-test":
        selfTest = true
    case "--run":
        index += 1
        guard index < rawArgs.count else {
            print("missing value for --run\n\(usage)")
            exit(2)
        }
        runConfigPath = rawArgs[index]
    case "--footprint":
        footprint = true
    case "--config":
        index += 1
        guard index < rawArgs.count else {
            print("missing value for --config\n\(usage)")
            exit(2)
        }
        footprintConfigPath = rawArgs[index]
    case "--limit-mb":
        index += 1
        guard index < rawArgs.count, let megabytes = Double(rawArgs[index]), megabytes > 0 else {
            print("missing or invalid value for --limit-mb\n\(usage)")
            exit(2)
        }
        footprintLimitBytes = Int64(megabytes * 1024 * 1024)
    case "--require-engine":
        requireEngine = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        print("unknown argument: \(arg)\n\(usage)")
        exit(2)
    }
    index += 1
}

guard geteuid() == 0 else {
    FileHandle.standardError.write("root required: run with sudo\n".data(using: .utf8)!)
    exit(1)
}

/// The configuration the app mirrors out of its App Group on every save. The
/// harness runs outside that sandbox, so this file is the only way to measure a
/// real profile. Absent until the app has saved at least once, and a missing
/// file is not an error: `runFootprint` falls back to a synthetic one.
func configurationMirrorPath() -> String? {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Waypo", isDirectory: true)
        .appendingPathComponent("tunnel-configuration.json")
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url.path
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UtunSetupError(message: "\(launchPath) \(args.joined(separator: " ")) failed: \(output)")
    }
    return output
}

do {
    if selfTest {
        exit(await runSelfTest(unit: unit, address: address, peerAddress: peerAddress))
    }
    if let configPath = runConfigPath {
        exit(await runTunnel(unit: unit, address: address, peerAddress: peerAddress, configPath: configPath))
    }
    if footprint {
        exit(await runFootprint(unit: unit, address: address, peerAddress: peerAddress,
                                configPath: footprintConfigPath ?? configurationMirrorPath(),
                                limitBytes: footprintLimitBytes,
                                requireEngine: requireEngine))
    }

    let utun = try UtunInterface(unit: unit)
    print("created \(utun.name)")

    try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])
    print("\(utun.name): local \(address), peer \(peerAddress)")

    if defaultRoute {
        try run("/sbin/route", ["-n", "add", "default", peerAddress])
        print("default route -> \(utun.name)")
    }

    let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)
    let engine = NullCoreEngine()
    try await engine.start(configuration: .default, packetFlow: flow)

    print("harness running on \(utun.name) — packets will be logged; Ctrl+C to stop")
    Task {
        for await packet in flow.readPackets() {
            let version = packet.first.map { $0 >> 4 } ?? 0
            print("-> \(packet.count) bytes, IPv\(version)")
        }
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
