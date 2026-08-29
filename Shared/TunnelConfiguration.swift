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

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, transport, credentials, cipher, useTLS, serverName
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, transport: String = "direct",
         credentials: String? = nil, cipher: String? = nil,
         useTLS: Bool = false, serverName: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.transport = transport
        self.credentials = credentials
        self.cipher = cipher
        self.useTLS = useTLS
        self.serverName = serverName
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
}
