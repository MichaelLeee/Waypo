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

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, transport, credentials, cipher, useTLS, serverName
        case network, wsPath, wsHost, serviceName, flow, realityPublicKey, realityShortID
        case obfs, obfsPassword, allowInsecure
        case uuid, alpn, congestionControl
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, transport: String = "direct",
         credentials: String? = nil, cipher: String? = nil,
         useTLS: Bool = false, serverName: String? = nil,
         network: String? = nil, wsPath: String? = nil, wsHost: String? = nil,
         serviceName: String? = nil, flow: String? = nil,
         realityPublicKey: String? = nil, realityShortID: String? = nil,
         obfs: String? = nil, obfsPassword: String? = nil, allowInsecure: Bool = false,
         uuid: String? = nil, alpn: String? = nil, congestionControl: String? = nil) {
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
    }
}

struct TunnelConfiguration: Codable, Hashable, Sendable {
    var servers: [TunnelServer]
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
