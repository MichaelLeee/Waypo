import Foundation

struct TunnelServer: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: Int

    /// Transport identifier understood by the engine (for example "direct").
    var transport: String = "direct"
    /// Shared secret or user credential, interpreted by the engine.
    var credentials: String?
    /// Cipher name for transports that take one.
    var cipher: String?
    var useTLS: Bool = false
    /// TLS server name override; defaults to `host` when TLS is enabled.
    var serverName: String?
    /// Overlay network above TCP: "ws" or "grpc"; nil/"tcp" is plain TCP.
    var network: String?
    /// WebSocket request path (network == "ws").
    var wsPath: String?
    /// WebSocket Host header override (network == "ws").
    var wsHost: String?
    /// gRPC service name (network == "grpc").
    var serviceName: String?
    /// VLESS flow control, e.g. "xtls-rprx-vision".
    var flow: String?
    /// Reality public key; its presence switches TLS into Reality mode.
    var realityPublicKey: String?
    var realityShortID: String?
    /// Obfuscation layer name, e.g. "salamander" (Hysteria2).
    var obfs: String?
    var obfsPassword: String?
    /// Skips certificate verification; servers with self-signed certs need it.
    var allowInsecure: Bool = false
    /// User identifier for transports that pair one with a password (TUIC).
    var uuid: String?
    /// Comma-separated TLS ALPN list.
    var alpn: String?
    /// QUIC congestion controller name, e.g. "bbr" (TUIC).
    var congestionControl: String?
    /// Legacy VMess alteration count; modern servers use 0.
    var alterId: Int?
    // WireGuard keys and settings (transport == "wireguard").
    var wgPrivateKey: String?
    var wgPeerPublicKey: String?
    var wgPresharedKey: String?
    /// Comma-separated interface CIDR addresses, e.g. "10.0.0.2/32, fd00::2/128".
    var wgAddresses: String?
    /// Comma-separated 3-byte header values, or the base64 form.
    var wgReserved: String?
    // Shadow-TLS outer layer (transport == "shadowtls"). The inner
    // Shadowsocks password stays in `credentials` and its cipher in `cipher`.
    var shadowTLSPassword: String?
    var shadowTLSVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, transport, credentials, cipher, useTLS, serverName
        case network, wsPath, wsHost, serviceName, flow, realityPublicKey, realityShortID
        case obfs, obfsPassword, allowInsecure
        case uuid, alpn, congestionControl
        case alterId
        case wgPrivateKey, wgPeerPublicKey, wgPresharedKey, wgAddresses, wgReserved
        case shadowTLSPassword, shadowTLSVersion
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, transport: String = "direct",
         credentials: String? = nil, cipher: String? = nil,
         useTLS: Bool = false, serverName: String? = nil,
         network: String? = nil, wsPath: String? = nil, wsHost: String? = nil,
         serviceName: String? = nil, flow: String? = nil,
         realityPublicKey: String? = nil, realityShortID: String? = nil,
         obfs: String? = nil, obfsPassword: String? = nil, allowInsecure: Bool = false,
         uuid: String? = nil, alpn: String? = nil, congestionControl: String? = nil,
         alterId: Int? = nil,
         wgPrivateKey: String? = nil, wgPeerPublicKey: String? = nil, wgPresharedKey: String? = nil,
         wgAddresses: String? = nil, wgReserved: String? = nil,
         shadowTLSPassword: String? = nil, shadowTLSVersion: Int? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.transport = transport
        self.credentials = credentials
        self.cipher = cipher
        self.useTLS = useTLS
        self.serverName = serverName
        self.network = network
        self.wsPath = wsPath
        self.wsHost = wsHost
        self.serviceName = serviceName
        self.flow = flow
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.obfs = obfs
        self.obfsPassword = obfsPassword
        self.allowInsecure = allowInsecure
        self.uuid = uuid
        self.alpn = alpn
        self.congestionControl = congestionControl
        self.alterId = alterId
        self.wgPrivateKey = wgPrivateKey
        self.wgPeerPublicKey = wgPeerPublicKey
        self.wgPresharedKey = wgPresharedKey
        self.wgAddresses = wgAddresses
        self.wgReserved = wgReserved
        self.shadowTLSPassword = shadowTLSPassword
        self.shadowTLSVersion = shadowTLSVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        transport = try container.decodeIfPresent(String.self, forKey: .transport) ?? "direct"
        credentials = try container.decodeIfPresent(String.self, forKey: .credentials)
        cipher = try container.decodeIfPresent(String.self, forKey: .cipher)
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        network = try container.decodeIfPresent(String.self, forKey: .network)
        wsPath = try container.decodeIfPresent(String.self, forKey: .wsPath)
        wsHost = try container.decodeIfPresent(String.self, forKey: .wsHost)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        flow = try container.decodeIfPresent(String.self, forKey: .flow)
        realityPublicKey = try container.decodeIfPresent(String.self, forKey: .realityPublicKey)
        realityShortID = try container.decodeIfPresent(String.self, forKey: .realityShortID)
        obfs = try container.decodeIfPresent(String.self, forKey: .obfs)
        obfsPassword = try container.decodeIfPresent(String.self, forKey: .obfsPassword)
        allowInsecure = try container.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        alpn = try container.decodeIfPresent(String.self, forKey: .alpn)
        congestionControl = try container.decodeIfPresent(String.self, forKey: .congestionControl)
        alterId = try container.decodeIfPresent(Int.self, forKey: .alterId)
        wgPrivateKey = try container.decodeIfPresent(String.self, forKey: .wgPrivateKey)
        wgPeerPublicKey = try container.decodeIfPresent(String.self, forKey: .wgPeerPublicKey)
        wgPresharedKey = try container.decodeIfPresent(String.self, forKey: .wgPresharedKey)
        wgAddresses = try container.decodeIfPresent(String.self, forKey: .wgAddresses)
        wgReserved = try container.decodeIfPresent(String.self, forKey: .wgReserved)
        shadowTLSPassword = try container.decodeIfPresent(String.self, forKey: .shadowTLSPassword)
        shadowTLSVersion = try container.decodeIfPresent(Int.self, forKey: .shadowTLSVersion)
    }
}

/// The group types the engine supports natively. `select` keeps whatever
/// member the user picks; `url-test` automatically uses the member with the
/// lowest measured latency. (Fallback and load-balance would need emulation
/// on top and are intentionally absent for now.)
enum PolicyGroupKind: String, Codable, Sendable, CaseIterable {
    case select
    case urlTest = "url-test"
}

struct PolicyGroup: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: PolicyGroupKind
    /// Server ids, in order. For `select` groups the first entry is the
    /// persisted selection, mirroring how the active server is kept at
    /// index 0 of the server list.
    var memberIDs: [TunnelServer.ID] = []
    /// Latency test target for `url-test` groups.
    var url: String = "https://www.gstatic.com/generate_204"
    /// Re-test interval for `url-test` groups, in seconds.
    var interval: TimeInterval = 300
}

struct TunnelConfiguration: Hashable, Sendable {
    var servers: [TunnelServer]
    var groups: [PolicyGroup] = []
    var mtu: Int
    var dnsAddresses: [String]

    static let `default` = TunnelConfiguration(
        servers: [
            TunnelServer(name: "Primary", host: "203.0.113.10", port: 443),
        ],
        mtu: 1500,
        dnsAddresses: ["1.1.1.1", "8.8.8.8"]
    )

    static let empty = TunnelConfiguration(servers: [], mtu: 1500, dnsAddresses: ["1.1.1.1", "8.8.8.8"])
}

extension TunnelConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case servers, groups, mtu, dnsAddresses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(groups, forKey: .groups)
        try container.encode(mtu, forKey: .mtu)
        try container.encode(dnsAddresses, forKey: .dnsAddresses)
    }

    /// `groups` postdates the original persistence format, so older saved
    /// configurations decode with an empty list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decode([TunnelServer].self, forKey: .servers)
        groups = try container.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? []
        mtu = try container.decode(Int.self, forKey: .mtu)
        dnsAddresses = try container.decode([String].self, forKey: .dnsAddresses)
    }
}
