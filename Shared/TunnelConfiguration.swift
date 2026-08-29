import Foundation

struct TunnelServer: Codable, Hashable, Sendable {
    var name: String
    var host: String
    var port: Int
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
