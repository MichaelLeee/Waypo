import Foundation
#if canImport(Libbox)
import Libbox
#endif

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// End-to-end data-path check: drives the real engine over a utun device and
/// verifies a UDP round trip with deterministic metrics (payload equality,
/// no loss, byte counters balance). Exits non-zero on any failure.
func runSelfTest(unit: Int32, address: String, peerAddress: String) async -> Int32 {
    do {
        try await performSelfTest(unit: unit, address: address, peerAddress: peerAddress)
        print("self-test PASSED")
        return 0
    } catch {
        FileHandle.standardError.write("self-test FAILED: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

private func performSelfTest(unit: Int32, address: String, peerAddress: String) async throws {
    let utun = try UtunInterface(unit: unit)
    print("created \(utun.name)")
    // The peer address is the echo destination too: the kernel installs a
    // host route through the device for a point-to-point peer, which is what
    // pushes interface-pinned test datagrams onto the file descriptor where
    // the engine reads them.
    try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])
    // The engine's tun inbound declares an IPv6 address alongside the IPv4
    // one; both must exist on the device or its stack fails to bind.
    try run("/sbin/ifconfig", [utun.name, "inet6", "fdfe:dcba:9876::1", "prefixlen", "126", "up"])
    // The engine dials the peer address to reach the on-host echo server
    // (with its dialer bound to lo0, see the engine configuration); aliasing
    // it onto the loopback device makes the host own it so that dial
    // local-delivers instead of following the peer route back into the
    // device. The address must also sit outside the utun subnet — the engine
    // refuses to dial any address inside the device's own prefixes.
    try run("/sbin/ifconfig", ["lo0", "alias", peerAddress, "255.255.255.255"])
    defer {
        try? run("/sbin/ifconfig", ["lo0", "-alias", peerAddress])
    }

    let echoServer = try UDPEchoServer(bindAddress: peerAddress)
    print("echo server listening on \(peerAddress):\(echoServer.port)")

    let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)
    let testSocket = try UDPTestSocket(bindAddress: address, interfaceName: utun.name)
    print("test socket bound to \(address):\(testSocket.port), pinned to \(utun.name)")

    #if !canImport(Libbox)
    throw SelfTestFailure(description: "engine library is not built into this harness")
    #else
    // Probe, before the engine exists: a datagram pinned to the utun device
    // must surface on its file descriptor. Writing to the descriptor would
    // only inject inbound traffic the engine never sees, so the kernel output
    // path is the only honest way to hand packets to the engine.
    echoServer.arm(expected: 1)
    let probePayload = Data("waypo-probe".utf8)
    try testSocket.send(probePayload, to: peerAddress, port: echoServer.port)
    let probePacket: Data? = await withTaskGroup(of: Data?.self) { group in
        group.addTask { await flow.readPackets().first { _ in true } }
        group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
    let probeHijacks = echoServer.waitForReceipts(timeout: 0.5)
    guard let probePacket, probePacket.range(of: probePayload) != nil else {
        throw SelfTestFailure(description: probeHijacks.isEmpty
            ? "probe datagram never reached the \(utun.name) file descriptor"
            : "kernel delivered the probe locally instead of through \(utun.name)")
    }
    print("probe datagram (\(probePacket.count) bytes) reached \(utun.name)")

    let configuration = TunnelConfiguration(
        servers: [TunnelServer(name: "self-test", host: peerAddress,
                               port: Int(echoServer.port), transport: "direct")],
        mtu: 1500,
        dnsAddresses: ["127.0.0.1"]
    )
    let engine = LibboxCoreEngine(tunFileDescriptor: utun.fileDescriptor)
    try await engine.start(configuration: configuration, packetFlow: flow)
    print("engine started")
    try await Task.sleep(nanoseconds: 1_000_000_000)

    let iterations = 5
    var payloads: [Data] = []
    for index in 0..<iterations {
        // Leading random bytes keep the payload from parsing as a DNS header
        // (any fixed prefix can land on bytes that the sniffer accepts).
        let marker = Data("waypo-self-test-\(index)-".utf8)
        payloads.append(Data((0..<12).map { _ in UInt8.random(in: 0...255) }) + marker)
    }

    echoServer.arm(expected: iterations)
    testSocket.arm(expected: iterations)
    var sentBytes = 0
    for payload in payloads {
        try testSocket.send(payload, to: peerAddress, port: echoServer.port)
        sentBytes += payload.count
    }
    print("sent \(iterations) datagrams (\(sentBytes) payload bytes) toward \(peerAddress) via \(utun.name)")

    let receipts = echoServer.waitForReceipts(timeout: 20)
    let replies = testSocket.waitForDatagrams(timeout: 20)

    await engine.stop()
    echoServer.close()
    testSocket.close()

    var failures: [String] = []
    if receipts.count != iterations {
        failures.append("echo server received \(receipts.count) of \(iterations) packets")
    }
    if replies.count != iterations {
        failures.append("received \(replies.count) of \(iterations) replies through the engine")
    }
    let payloadSet = Set(payloads)
    for (index, receipt) in receipts.enumerated() where !payloadSet.contains(receipt) {
        failures.append("receipt \(index) payload mismatch")
    }
    for (index, reply) in replies.enumerated() where !payloadSet.contains(reply) {
        failures.append("reply \(index) payload mismatch")
    }
    let receivedBytes = receipts.reduce(0) { $0 + $1.count }
    let replyBytes = replies.reduce(0) { $0 + $1.count }
    print("metrics: sent=\(iterations)/\(sentBytes)B echoed=\(receipts.count)/\(receivedBytes)B replies=\(replies.count)/\(replyBytes)B")
    if receivedBytes != sentBytes {
        failures.append("byte counters do not balance: sent \(sentBytes), echoed \(receivedBytes)")
    }
    if replyBytes != sentBytes {
        failures.append("byte counters do not balance: sent \(sentBytes), received back \(replyBytes)")
    }
    if !failures.isEmpty {
        throw SelfTestFailure(description: failures.joined(separator: "; "))
    }
    #endif
}

/// Lock-protected datagram collector shared between a socket class and the
/// DispatchSource handler it installs. Kept separate from the owning class so
/// init-time handlers capture this instead of `self`, which Swift forbids
/// before all stored properties are initialized.
private final class SocketLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    private var expected = 0
    private let semaphore = DispatchSemaphore(value: 0)

    func reset(expected: Int) {
        lock.lock()
        items = []
        self.expected = expected
        lock.unlock()
    }

    func append(_ data: Data) {
        lock.lock()
        items.append(data)
        let done = expected > 0 && items.count >= expected
        lock.unlock()
        if done { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> [Data] {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// UDP echo server for the self-test. Receives datagrams, echoes each back to
/// its sender, and records receipts for verification.
final class UDPEchoServer: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.echo")
    private let log = SocketLog()
    private var readSource: DispatchSourceRead?
    private(set) var port: UInt16

    init(bindAddress: String) throws {
        fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard fileDescriptor >= 0 else {
            throw SelfTestFailure(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        // Closures below must capture this local, not self: instance properties
        // stay uninitialized until the end of init.
        let fd = fileDescriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bad bind address \(bindAddress)")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bind(\(bindAddress)) failed: \(message)")
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "getsockname() failed: \(message)")
        }
        port = boundAddress.sin_port.bigEndian

        let log = self.log
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            guard count > 0 else { return }
            _ = withUnsafePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, &buffer, count, 0, $0, senderLength)
                }
            }
            log.append(Data(buffer.prefix(count)))
        }
        source.resume()
        readSource = source
    }

    func arm(expected: Int) {
        log.reset(expected: expected)
    }

    func waitForReceipts(timeout: TimeInterval) -> [Data] {
        log.wait(timeout: timeout)
    }

    func close() {
        readSource?.cancel()
        Darwin.close(fileDescriptor)
    }
}

/// UDP socket pinned to the utun device. Output goes through the device's
/// kernel route, so datagrams surface on its file descriptor where the engine
/// reads them; the engine's replies come back to the same socket via local
/// delivery, proving the full return path.
final class UDPTestSocket: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.test")
    private let log = SocketLog()
    private var readSource: DispatchSourceRead?
    private(set) var port: UInt16

    init(bindAddress: String, interfaceName: String) throws {
        fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard fileDescriptor >= 0 else {
            throw SelfTestFailure(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        // Closures below must capture this local, not self: instance properties
        // stay uninitialized until the end of init.
        let fd = fileDescriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bad bind address \(bindAddress)")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bind(\(bindAddress)) failed: \(message)")
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "getsockname() failed: \(message)")
        }
        port = boundAddress.sin_port.bigEndian

        // Without the interface pin the kernel would deliver datagrams for the
        // loopback alias directly instead of handing them to the engine.
        let interfaceIndex = if_nametoindex(interfaceName)
        guard interfaceIndex > 0 else {
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "unknown interface \(interfaceName)")
        }
        var pinnedIndex = interfaceIndex
        let pinned = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &pinnedIndex,
                                socklen_t(MemoryLayout<UInt32>.size))
        guard pinned == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "IP_BOUND_IF(\(interfaceName)) failed: \(message)")
        }

        let log = self.log
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            guard count > 0 else { return }
            log.append(Data(buffer.prefix(count)))
        }
        source.resume()
        readSource = source
    }

    func arm(expected: Int) {
        log.reset(expected: expected)
    }

    func waitForDatagrams(timeout: TimeInterval) -> [Data] {
        log.wait(timeout: timeout)
    }

    func send(_ payload: Data, to host: String, port: UInt16) throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else {
            throw SelfTestFailure(description: "bad destination address \(host)")
        }
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                payload.withUnsafeBytes { buffer in
                    sendto(fileDescriptor, buffer.baseAddress, buffer.count, 0, sockaddrPointer,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else {
            throw SelfTestFailure(description: "sendto(\(host):\(port)) failed: \(String(cString: strerror(errno)))")
        }
    }

    func close() {
        readSource?.cancel()
        Darwin.close(fileDescriptor)
    }
}
