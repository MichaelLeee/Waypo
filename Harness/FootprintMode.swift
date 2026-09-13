import Foundation
#if canImport(Libbox)
import Libbox
#endif

/// `--footprint` mode: brings up the real engine over a utun device, pushes a
/// little traffic through it, and reports this process's memory at each phase.
///
/// The number is the one a tunnel extension is killed for: `phys_footprint`,
/// not the resident size. It is measured in a separate process from the
/// extension, so it is a proxy — the same engine, the same configuration, the
/// same traffic, without the extension loader or the device's own limit. It is
/// still the only figure available off-device, and it is directly comparable
/// between commits, which is what makes it useful as a regression gate.
///
/// Nothing here fails the build on an engine problem. A measurement that reds a
/// run because a utun device was busy teaches people to ignore it; only
/// `--require-engine` combined with an over-budget reading exits non-zero.
func runFootprint(unit: Int32,
                  address: String,
                  peerAddress: String,
                  configPath: String?,
                  limitBytes: Int64,
                  requireEngine: Bool) async -> Int32 {
#if canImport(Libbox)
    var trace = MemoryTrace(budgetBytes: limitBytes)
    // The first reading is the floor: everything above it was bought by the
    // engine, the device, and the traffic.
    trace.mark("before-engine")

    func finish(_ status: Int32) -> Int32 {
        for line in trace.reportLines {
            print(line)
        }
        guard status == 0 else { return status }
        guard requireEngine, trace.isOverBudget else { return 0 }
        FileHandle.standardError.write(
            "footprint \(trace.peakPhysFootprintBytes ?? -1) bytes exceeds the \(limitBytes) byte budget\n"
                .data(using: .utf8)!)
        return 1
    }

    var explicit: TunnelConfiguration?
    if let configPath {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            FileHandle.standardError.write("configuration file not found: \(configPath)\n".data(using: .utf8)!)
            return finish(1)
        }
        do {
            explicit = try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        } catch {
            FileHandle.standardError.write("cannot decode configuration: \(error)\n".data(using: .utf8)!)
            return finish(1)
        }
    }

    do {
        let utun = try UtunInterface(unit: unit)
        print("created \(utun.name)")
        try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])
        // The engine's tun inbound declares an IPv6 address alongside the IPv4
        // one; both must exist on the device or its stack fails to bind.
        try run("/sbin/ifconfig", [utun.name, "inet6", "fdfe:dcba:9876::1", "prefixlen", "126", "up"])

        let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)

        // Traffic is what separates "the engine is loaded" from "the engine is
        // working". A configuration supplied by the caller may route the echo
        // destination somewhere that never answers, so the round trip is
        // reported but never required.
        let echoServer = try UDPEchoServer(bindAddress: "127.0.0.1")
        print("echo server listening on 127.0.0.1:\(echoServer.port)")
        let testSocket = try UDPTestSocket(bindAddress: address, interfaceName: utun.name)

        let configuration = explicit ?? TunnelConfiguration(
            servers: [TunnelServer(name: "footprint", host: peerAddress,
                                   port: Int(echoServer.port), transport: "direct")],
            mtu: 1500,
            dnsAddresses: ["127.0.0.1"]
        )

        let engine = LibboxCoreEngine(tunFileDescriptor: utun.fileDescriptor)
        do {
            try await engine.start(configuration: configuration, packetFlow: flow)
        } catch {
            FileHandle.standardError.write("engine did not start: \(error)\n".data(using: .utf8)!)
            echoServer.close()
            testSocket.close()
            return finish(0)
        }
        trace.mark("engine-started")
        print("engine started")

        let iterations = 5
        echoServer.arm(expected: iterations)
        var sentBytes = 0
        for index in 0..<iterations {
            // Leading random bytes keep the payload from parsing as a DNS
            // header (any fixed prefix can land on bytes the sniffer accepts).
            let marker = Data("waypo-footprint-\(index)-".utf8)
            let payload = Data((0..<12).map { _ in UInt8.random(in: 0...255) }) + marker
            try testSocket.send(payload, to: peerAddress, port: echoServer.port)
            sentBytes += payload.count
        }
        let receipts = echoServer.waitForReceipts(timeout: 5)
        print("traffic: sent=\(iterations)/\(sentBytes)B echoed=\(receipts.count)")

        await engine.stop()
        trace.mark("stopped")
        print("engine stopped")

        echoServer.close()
        testSocket.close()
        return finish(0)
    } catch {
        FileHandle.standardError.write("footprint run failed: \(error)\n".data(using: .utf8)!)
        return finish(1)
    }
#else
    FileHandle.standardError.write("--footprint requires the packaged core library (build with Libbox.xcframework)\n"
                                       .data(using: .utf8)!)
    return 1
#endif
}
