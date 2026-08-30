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
    try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])

    let echoServer = try UDPEchoServer()
    print("echo server listening on 0.0.0.0:\(echoServer.port)")

    guard let destination = SelfTestHelpers.hostDestination() else {
        throw SelfTestFailure(description: "no routable host IPv4 address found")
    }
    print("test destination \(destination):\(echoServer.port)")

    let replySocket = try UDPReceiveSocket(bindAddress: address)
    print("reply socket bound to \(address):\(replySocket.port)")

    let configuration = TunnelConfiguration(
        servers: [TunnelServer(name: "self-test", host: destination,
                               port: Int(echoServer.port), transport: "direct")],
        mtu: 1500,
        dnsAddresses: ["127.0.0.1"]
    )
    let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)

    #if !canImport(Libbox)
    throw SelfTestFailure(description: "engine library is not built into this harness")
    #else
    let engine = LibboxCoreEngine(tunFileDescriptor: utun.fileDescriptor)
    try await engine.start(configuration: configuration, packetFlow: flow)
    print("engine started")
    try await Task.sleep(nanoseconds: 1_000_000_000)

    let iterations = 5
    var payloads: [Data] = []
    for index in 0..<iterations {
        let random = (0..<32).map { _ in UInt8.random(in: 0...255) }
        payloads.append(Data("waypo-self-test-\(index)-".utf8) + Data(random))
    }

    echoServer.arm(expected: iterations)
    replySocket.arm(expected: iterations)
    var sentBytes = 0
    for payload in payloads {
        let packet = try SelfTestHelpers.ipv4UdpPacket(
            sourceAddress: address, sourcePort: replySocket.port,
            destinationAddress: destination, destinationPort: echoServer.port,
            payload: payload)
        await flow.writePackets([packet])
        sentBytes += payload.count
    }
    print("injected \(iterations) packets (\(sentBytes) payload bytes) into \(utun.name)")

    let receipts = echoServer.waitForReceipts(timeout: 20)
    let replies = replySocket.waitForDatagrams(timeout: 20)

    await engine.stop()
    echoServer.close()
    replySocket.close()

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
    print("metrics: injected=\(iterations)/\(sentBytes)B echoed=\(receipts.count)/\(receivedBytes)B replies=\(replies.count)/\(replyBytes)B")
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

enum SelfTestHelpers {
    /// Best non-loopback IPv4 address of the host, preferring the primary
    /// Ethernet/Wi-Fi interface, so the engine dials a real on-host address.
    static func hostDestination() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sockaddrPtr = current.pointee.ifa_addr,
                  sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sockaddrPtr, socklen_t(sockaddrPtr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let address = String(cString: host)
            guard !address.hasPrefix("127."), !name.hasPrefix("utun"), !name.hasPrefix("lo"),
                  !name.hasPrefix("bridge"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            candidates.append((name, address))
        }
        return candidates.first(where: { $0.name.hasPrefix("en") })?.address ?? candidates.first?.address
    }

    static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    /// Builds a checksummed IPv4 + UDP datagram.
    static func ipv4UdpPacket(sourceAddress: String, sourcePort: UInt16,
                              destinationAddress: String, destinationPort: UInt16,
                              payload: Data) throws -> Data {
        var source = in_addr()
        var destination = in_addr()
        guard inet_pton(AF_INET, sourceAddress, &source) == 1 else {
            throw SelfTestFailure(description: "bad source address \(sourceAddress)")
        }
        guard inet_pton(AF_INET, destinationAddress, &destination) == 1 else {
            throw SelfTestFailure(description: "bad destination address \(destinationAddress)")
        }

        let udpLength = 8 + payload.count
        var udp = [UInt8](repeating: 0, count: udpLength)
        udp[0] = UInt8(sourcePort >> 8 & 0xFF)
        udp[1] = UInt8(sourcePort & 0xFF)
        udp[2] = UInt8(destinationPort >> 8 & 0xFF)
        udp[3] = UInt8(destinationPort & 0xFF)
        udp[4] = UInt8(udpLength >> 8 & 0xFF)
        udp[5] = UInt8(udpLength & 0xFF)
        payload.copyBytes(to: &udp[8], count: payload.count)

        var pseudo: [UInt8] = []
        withUnsafeBytes(of: source.s_addr) { pseudo.append(contentsOf: $0) }
        withUnsafeBytes(of: destination.s_addr) { pseudo.append(contentsOf: $0) }
        pseudo.append(0)
        pseudo.append(17)
        pseudo.append(UInt8(udpLength >> 8 & 0xFF))
        pseudo.append(UInt8(udpLength & 0xFF))
        let checksum = internetChecksum(pseudo + udp)
        udp[6] = UInt8(checksum >> 8)
        udp[7] = UInt8(checksum & 0xFF)

        let totalLength = 20 + udpLength
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        ip[2] = UInt8(totalLength >> 8 & 0xFF)
        ip[3] = UInt8(totalLength & 0xFF)
        ip[4] = 0x12
        ip[5] = 0x34
        ip[6] = 0x40
        ip[8] = 64
        ip[9] = 17
        withUnsafeBytes(of: source.s_addr) { for offset in 0..<4 { ip[12 + offset] = $0[offset] } }
        withUnsafeBytes(of: destination.s_addr) { for offset in 0..<4 { ip[16 + offset] = $0[offset] } }
        let ipChecksum = internetChecksum(ip)
        ip[10] = UInt8(ipChecksum >> 8)
        ip[11] = UInt8(ipChecksum & 0xFF)

        return Data(ip + udp)
    }
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

    init() throws {
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
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bind() failed: \(message)")
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

/// UDP socket bound to the tun address; the engine's responses to the injected
/// packets are delivered here by the kernel, proving the full return path.
final class UDPReceiveSocket: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.reply")
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

    func close() {
        readSource?.cancel()
        Darwin.close(fileDescriptor)
    }
}
