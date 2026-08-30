import Foundation
#if canImport(Libbox)
import Libbox
#endif

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// End-to-end data-path check: drives the real engine over a utun device and
/// verifies a UDP round trip, a byte-exact TCP stream, DNS resolution through
/// the engine's resolver, and prompt clean shutdown, all with deterministic
/// metrics. Exits non-zero on any failure.
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
    if let routeLookup = try? run("/usr/sbin/route", ["-n", "get", peerAddress]) {
        print("route to \(peerAddress): \(routeLookup.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    // The engine dials the on-host echo server at loopback via a route-rule
    // address override (see the engine configuration), so the peer address is
    // never dialed and may sit inside the device's own subnet — but it must
    // NOT be owned by any other interface: an alias elsewhere steals the peer
    // host route and datagrams pinned to the device then vanish.

    let echoServer = try UDPEchoServer(bindAddress: "127.0.0.1")
    print("echo server listening on 127.0.0.1:\(echoServer.port)")

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
    // Scan until the probe payload shows up: the kernel emits its own IPv6
    // neighbor-discovery traffic on the device right after configuration, and
    // that can arrive before the probe does.
    let probePacket: Data? = await withTaskGroup(of: Data?.self) { group in
        group.addTask {
            for await packet in flow.readPackets() where packet.range(of: probePayload) != nil {
                return packet
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
    let probeHijacks = echoServer.waitForReceipts(timeout: 0.5)
    guard let probePacket else {
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

    echoServer.close()
    testSocket.close()

    // TCP: the engine's stack terminates the connection from the pinned test
    // socket and dials the on-host echo server; a stream must come back byte
    // for byte, in order.
    let tcpEchoServer = try TCPEchoServer()
    print("tcp echo server listening on 127.0.0.1:\(tcpEchoServer.port)")
    let tcpSocket = try TCPTestSocket(bindAddress: address, interfaceName: utun.name)
    try tcpSocket.connect(to: peerAddress, port: tcpEchoServer.port, timeout: 15)
    print("tcp connection through the engine established")
    tcpEchoServer.arm(expectedBytes: sentBytes)
    let (tcpSentBytes, tcpReceived) = try tcpSocket.roundTrip(payloads: payloads, timeout: 20)
    let tcpEchoedBytes = tcpEchoServer.waitForBytes(timeout: 2)
    print("tcp metrics: sent=\(tcpSentBytes)B echoed=\(tcpEchoedBytes)B received-back=\(tcpReceived.count)B")
    if tcpEchoedBytes != tcpSentBytes {
        failures.append("tcp echo server received \(tcpEchoedBytes) of \(tcpSentBytes) bytes")
    }
    if tcpReceived != payloads.reduce(into: Data()) { $0.append($1) } {
        failures.append("tcp stream came back altered: \(tcpReceived.count) of \(tcpSentBytes) bytes")
    }
    tcpSocket.close()
    tcpEchoServer.close()

    // DNS: queries to port 53 are hijacked by the engine's resolver, which
    // must ask the on-host test responder and return its answer.
    let dnsServer = try MiniDNSServer()
    print("dns responder listening on 127.0.0.1:53")
    let dnsSocket = try UDPTestSocket(bindAddress: address, interfaceName: utun.name)
    let dnsQuery = makeDNSQuery(id: 0x1A2B, name: "self-test.internal")
    dnsServer.arm(expected: 1)
    dnsSocket.arm(expected: 1)
    try dnsSocket.send(dnsQuery, to: peerAddress, port: 53)
    let dnsQueries = dnsServer.waitForReceipts(timeout: 10)
    let dnsReplies = dnsSocket.waitForDatagrams(timeout: 10)
    print("dns metrics: queries=\(dnsQueries.count) replies=\(dnsReplies.count)")
    if dnsQueries.count != 1 {
        failures.append("dns responder received \(dnsQueries.count) of 1 queries from the engine")
    } else if dnsQueries[0].range(of: Data("self-test.internal".utf8)) == nil {
        failures.append("engine dns query does not carry the test name")
    }
    if let dnsReply = dnsReplies.first {
        if dnsReply.prefix(2) != Data([0x1A, 0x2B]) {
            failures.append("dns reply transaction id mismatch")
        }
        if dnsReply.range(of: MiniDNSServer.answeredAddress) == nil {
            failures.append("dns reply missing the responder answer")
        }
    } else {
        failures.append("no dns reply through the engine")
    }
    dnsSocket.close()
    dnsServer.close()

    // Clean shutdown: stopping the engine must drain and return promptly.
    let stopStart = Date()
    await engine.stop()
    let stopElapsed = Date().timeIntervalSince(stopStart)
    print("engine stopped in \(String(format: "%.1f", stopElapsed))s")
    if stopElapsed > 10 {
        failures.append("engine shutdown took \(stopElapsed)s")
    }

    if !failures.isEmpty {
        throw SelfTestFailure(description: failures.joined(separator: "; "))
    }
    #endif
}

private func makeDNSQuery(id: UInt16, name: String) -> Data {
    var data = Data()
    data.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Data($0) })
    data.append(contentsOf: [0x01, 0x00]) // recursion desired
    data.append(contentsOf: [0, 1, 0, 0, 0, 0, 0, 0]) // one question, no records
    for label in name.split(separator: ".") {
        data.append(UInt8(label.count))
        data.append(contentsOf: label.utf8)
    }
    data.append(0)
    data.append(contentsOf: [0, 1, 0, 1]) // A, IN
    return data
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

/// Lock-protected byte counter for stream servers, mirroring SocketLog but
/// counting bytes instead of collecting datagrams.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var expected = 0
    private let semaphore = DispatchSemaphore(value: 0)

    func reset(expected: Int) {
        lock.lock()
        total = 0
        self.expected = expected
        lock.unlock()
    }

    func add(_ n: Int) {
        lock.lock()
        total += n
        let done = expected > 0 && total >= expected
        lock.unlock()
        if done { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Int {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// TCP echo server on the host loopback. Accepts one connection at a time and
/// echoes every byte it reads, counting received bytes for verification.
final class TCPEchoServer: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.tcpecho")
    private let counter = ByteCounter()
    private var acceptSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private(set) var port: UInt16 = 0

    init() throws {
        fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw SelfTestFailure(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        let fd = fileDescriptor
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bad bind address 127.0.0.1")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bind(127.0.0.1) failed: \(message)")
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
        guard listen(fd, 1) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "listen() failed: \(message)")
        }

        let counter = self.counter
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var client = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let acceptedFD = withUnsafeMutablePointer(to: &client) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLength)
                }
            }
            guard acceptedFD >= 0 else { return }
            self.clientFD = acceptedFD
            let clientSource = DispatchSource.makeReadSource(fileDescriptor: acceptedFD, queue: queue)
            clientSource.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 65536)
                let count = read(acceptedFD, &buffer, buffer.count)
                guard count > 0 else { return }
                var sent = 0
                while sent < count {
                    let n = buffer.withUnsafeBytes { raw in
                        Darwin.send(acceptedFD, raw.baseAddress!.advanced(by: sent), count - sent, 0)
                    }
                    guard n > 0 else { return }
                    sent += n
                }
                counter.add(count)
            }
            clientSource.resume()
            self.clientSource = clientSource
        }
        source.resume()
        acceptSource = source
    }

    func arm(expectedBytes: Int) {
        counter.reset(expected: expectedBytes)
    }

    func waitForBytes(timeout: TimeInterval) -> Int {
        counter.wait(timeout: timeout)
    }

    func close() {
        acceptSource?.cancel()
        clientSource?.cancel()
        if clientFD >= 0 { Darwin.close(clientFD) }
        Darwin.close(fileDescriptor)
    }
}

/// Blocking TCP socket pinned to the utun device; connects through the
/// engine's stack the same way UDPTestSocket routes datagrams.
final class TCPTestSocket: @unchecked Sendable {
    private let fileDescriptor: Int32

    init(bindAddress: String, interfaceName: String) throws {
        fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw SelfTestFailure(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        let fd = fileDescriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
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
    }

    /// Non-blocking connect bounded by a deadline; a blackholed connection
    /// fails fast instead of hanging the CI job on the kernel default.
    func connect(to host: String, port: UInt16, timeout: TimeInterval) throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else {
            throw SelfTestFailure(description: "bad destination address \(host)")
        }
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        let connectResult = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                throw SelfTestFailure(description: "connect(\(host):\(port)) failed: \(String(cString: strerror(errno)))")
            }
            var fds = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&fds, 1, Int32(timeout * 1000))
            guard ready > 0 else {
                throw SelfTestFailure(description: "connect(\(host):\(port)) timed out after \(timeout)s")
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fileDescriptor, SOL_SOCKET, SO_ERROR, &soError, &length)
            guard soError == 0 else {
                throw SelfTestFailure(description: "connect(\(host):\(port)) failed: \(String(cString: strerror(soError)))")
            }
        }
        fcntl(fileDescriptor, F_SETFL, flags)
    }

    /// Writes every payload then reads until the same byte count returns or
    /// the deadline passes. A TCP stream preserves order, so the caller can
    /// compare the received data with the concatenated payloads directly.
    func roundTrip(payloads: [Data], timeout: TimeInterval) throws -> (sent: Int, received: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        var sent = 0
        for payload in payloads {
            let written = payload.withUnsafeBytes { buffer in
                write(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard written == payload.count else {
                throw SelfTestFailure(description: "tcp write failed: \(String(cString: strerror(errno)))")
            }
            sent += payload.count
        }
        var received = Data()
        while received.count < sent {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var fds = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, Int32(remaining * 1000)) > 0 else { break }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return (sent, received)
    }

    func close() {
        Darwin.close(fileDescriptor)
    }
}

/// Minimal UDP DNS responder on 127.0.0.1:53. Answers every query with a
/// single fixed A record so the engine's resolver path is verifiable by
/// payload bytes alone. Binds a privileged port; the harness runs as root.
final class MiniDNSServer: @unchecked Sendable {
    static let answeredAddress = Data([203, 0, 113, 7])
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "org.waypo.harness.dns")
    private let log = SocketLog()
    private var readSource: DispatchSourceRead?

    init() throws {
        fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard fileDescriptor >= 0 else {
            throw SelfTestFailure(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        let fd = fileDescriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bad bind address 127.0.0.1")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw SelfTestFailure(description: "bind(127.0.0.1:53) failed: \(message)")
        }

        let log = self.log
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            guard count > 12 else { return }
            let query = Data(buffer.prefix(count))
            log.append(query)
            let response = Self.buildResponse(for: query)
            _ = response.withUnsafeBytes { raw in
                withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, senderLength)
                    }
                }
            }
        }
        source.resume()
        readSource = source
    }

    /// Copies the transaction id and question from the query and appends one
    /// A record pointing at the fixed answer address.
    static func buildResponse(for query: Data) -> Data {
        var index = 12
        while index < query.count {
            let length = query[index]
            index += 1
            if length == 0 { break }
            index += Int(length)
        }
        index += 4 // qtype + qclass
        var response = Data(query.prefix(2))
        response.append(contentsOf: [0x81, 0x80]) // response, recursion available
        response.append(contentsOf: [0, 1, 0, 1, 0, 0, 0, 0]) // one question, one answer
        if index <= query.count {
            response.append(query[12..<index])
        }
        response.append(contentsOf: [0xC0, 0x0C]) // pointer to the question name
        response.append(contentsOf: [0, 1, 0, 1]) // A, IN
        response.append(contentsOf: [0, 0, 0, 60]) // ttl
        response.append(contentsOf: [0, 4])
        response.append(answeredAddress)
        return response
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

        // Without the interface pin a datagram to an address the host owns
        // would be delivered locally instead of handed to the engine; the
        // peer route alone is not trusted to win that race.
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
