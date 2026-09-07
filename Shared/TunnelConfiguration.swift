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

/// One resolver the engine's DNS client queries. Plain UDP plus the three
/// encrypted transports the engine supports.
struct DNSResolver: Hashable, Sendable, Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case udp
        case https
        case tls
        case quic
    }

    var id: UUID = UUID()
    var kind: Kind = .udp
    var server: String
    /// Nil means the transport default (53 for udp, 443 otherwise).
    var serverPort: Int?
    /// URL path for DoH; nil means the standard /dns-query.
    var path: String?

    init(id: UUID = UUID(), kind: Kind = .udp, server: String, serverPort: Int? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.server = server
        self.serverPort = serverPort
        self.path = path
    }
}

/// A static domain → address answer served by the engine's hosts resolver.
struct DNSHostMapping: Hashable, Sendable, Codable, Identifiable {
    var id: UUID = UUID()
    var domain: String
    var address: String

    init(id: UUID = UUID(), domain: String, address: String) {
        self.id = id
        self.domain = domain
        self.address = address
    }
}

/// One ordered routing rule. Matching criteria combine with AND; every
/// listed value within one criterion matches as OR. Empty rules are ignored
/// by the config builder.
struct RoutingRule: Hashable, Sendable, Codable, Identifiable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case route
        case reject
        case direct
    }

    var id: UUID = UUID()
    var domains: [String] = []
    var domainSuffixes: [String] = []
    var domainKeywords: [String] = []
    /// IP networks in CIDR form.
    var ipCIDRs: [String] = []
    var ports: [Int] = []
    /// Tags of rule-sets this rule matches against.
    var ruleSetTags: [String] = []
    /// Negates the whole match.
    var invert = false
    var action: Action = .route
    /// Route target for `.route`: a server or group id; nil is the top
    /// selector (the active endpoint).
    var outboundID: UUID?

    var matchesSomething: Bool {
        !domains.isEmpty || !domainSuffixes.isEmpty || !domainKeywords.isEmpty
            || !ipCIDRs.isEmpty || !ports.isEmpty || !ruleSetTags.isEmpty
    }

    init(id: UUID = UUID(), domains: [String] = [], domainSuffixes: [String] = [],
         domainKeywords: [String] = [], ipCIDRs: [String] = [], ports: [Int] = [],
         ruleSetTags: [String] = [], invert: Bool = false, action: Action = .route,
         outboundID: UUID? = nil) {
        self.id = id
        self.domains = domains
        self.domainSuffixes = domainSuffixes
        self.domainKeywords = domainKeywords
        self.ipCIDRs = ipCIDRs
        self.ports = ports
        self.ruleSetTags = ruleSetTags
        self.invert = invert
        self.action = action
        self.outboundID = outboundID
    }
}

/// A remote rule-set the engine downloads and refreshes itself.
struct RemoteRuleSet: Hashable, Sendable, Codable, Identifiable {
    var id: UUID = UUID()
    /// Display name; the engine references the set by its generated tag.
    var name: String
    var url: String
    /// Seconds between refreshes; the engine default is one day.
    var updateInterval: TimeInterval = 86400

    init(id: UUID = UUID(), name: String, url: String, updateInterval: TimeInterval = 86400) {
        self.id = id
        self.name = name
        self.url = url
        self.updateInterval = updateInterval
    }
}

struct TunnelConfiguration: Hashable, Sendable {
    var servers: [TunnelServer]
    var groups: [PolicyGroup] = []
    var mtu: Int
    var dnsResolvers: [DNSResolver]
    var dnsHosts: [DNSHostMapping] = []
    var fakeIPEnabled = false
    /// Domain suffixes that never receive fake addresses.
    var fakeIPExclusions: [String] = []
    /// Ordered routing rules, evaluated before the final outbound.
    var rules: [RoutingRule] = []
    var ruleSets: [RemoteRuleSet] = []

    /// Plain resolver addresses, for consumers that only need hosts
    /// (the system tunnel settings). Assigning converts to UDP resolvers.
    var dnsAddresses: [String] {
        get { dnsResolvers.map(\.server) }
        set { dnsResolvers = newValue.map { DNSResolver(server: $0) } }
    }

    init(servers: [TunnelServer], groups: [PolicyGroup] = [], mtu: Int,
         dnsAddresses: [String] = [], dnsResolvers: [DNSResolver]? = nil,
         dnsHosts: [DNSHostMapping] = [], fakeIPEnabled: Bool = false,
         fakeIPExclusions: [String] = [], rules: [RoutingRule] = [],
         ruleSets: [RemoteRuleSet] = []) {
        self.servers = servers
        self.groups = groups
        self.mtu = mtu
        self.dnsResolvers = dnsResolvers
            ?? (!dnsAddresses.isEmpty ? dnsAddresses.map { DNSResolver(server: $0) }
                                       : [DNSResolver(server: "1.1.1.1")])
        self.dnsHosts = dnsHosts
        self.fakeIPEnabled = fakeIPEnabled
        self.fakeIPExclusions = fakeIPExclusions
        self.rules = rules
        self.ruleSets = ruleSets
    }

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
        case servers, groups, mtu
        case dnsResolvers, dnsHosts, fakeIPEnabled, fakeIPExclusions
        case rules, ruleSets
        case dnsAddresses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(groups, forKey: .groups)
        try container.encode(mtu, forKey: .mtu)
        try container.encode(dnsResolvers, forKey: .dnsResolvers)
        try container.encode(dnsHosts, forKey: .dnsHosts)
        if fakeIPEnabled {
            try container.encode(fakeIPEnabled, forKey: .fakeIPEnabled)
            try container.encode(fakeIPExclusions, forKey: .fakeIPExclusions)
        }
        try container.encode(rules, forKey: .rules)
        try container.encode(ruleSets, forKey: .ruleSets)
    }

    /// `groups`, the DNS settings, and the rules postdate the original
    /// persistence format, so older saved configurations decode with
    /// defaults; the original plain `dnsAddresses` list converts to UDP
    /// resolvers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decode([TunnelServer].self, forKey: .servers)
        groups = try container.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? []
        mtu = try container.decode(Int.self, forKey: .mtu)
        if let resolvers = try container.decodeIfPresent([DNSResolver].self, forKey: .dnsResolvers),
           !resolvers.isEmpty {
            dnsResolvers = resolvers
        } else {
            let legacy = try container.decodeIfPresent([String].self, forKey: .dnsAddresses) ?? []
            dnsResolvers = legacy.map { DNSResolver(server: $0) }
        }
        dnsHosts = try container.decodeIfPresent([DNSHostMapping].self, forKey: .dnsHosts) ?? []
        fakeIPEnabled = try container.decodeIfPresent(Bool.self, forKey: .fakeIPEnabled) ?? false
        fakeIPExclusions = try container.decodeIfPresent([String].self, forKey: .fakeIPExclusions) ?? []
        rules = try container.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
        ruleSets = try container.decodeIfPresent([RemoteRuleSet].self, forKey: .ruleSets) ?? []
    }
}
