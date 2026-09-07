import Foundation

/// Where the engine accepts traffic from.
enum EngineInbound: Sendable, Equatable {
    /// A tun device. `autoRoute` enables engine-managed routes (production,
    /// and the harness `--run` mode; the harness self-test manages its own).
    case tun(autoRoute: Bool)
    /// macOS system-wide mode: a loopback listener for web and SOCKS traffic.
    case mixedListener(port: Int)
}

/// Translation of a `TunnelConfiguration` into the engine's JSON configuration
/// format. Kept free of the packaged engine library so the mapping can be
/// unit-tested without it.
enum EngineConfigBuilder {
    static func makeContent(_ configuration: TunnelConfiguration, inbound: EngineInbound) throws -> String {
        let server = configuration.servers.first ?? TunnelServer(name: "Primary", host: "203.0.113.10", port: 443)

        let dnsServers: [[String: Any]] = configuration.dnsAddresses.enumerated().map { index, address in
            ["type": "udp", "tag": "dns-\(index)", "server": address]
        }

        let inbounds: [[String: Any]]
        switch inbound {
        case .tun(let autoRoute):
            // The engine's stack hijacks DNS by default, targeting the address
            // right after the tun's own (198.18.0.2 for a 198.18.0.1/30 device) —
            // which is exactly where harness test traffic goes. Harness mode
            // therefore disables it; production keeps the default behavior.
            inbounds = [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["198.18.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": configuration.mtu,
                "auto_route": autoRoute,
                "strict_route": autoRoute,
                "stack": "system",
                "dns_mode": autoRoute ? "hijack" : "disabled",
            ]]
        case .mixedListener(let port):
            // HTTP CONNECT and SOCKS carry hostnames inline, so no DNS
            // hijacking is needed in this mode.
            inbounds = [[
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": port,
            ]]
        }

        let remoteOutbounds = configuration.servers.filter { $0.transport != "direct" }
        // A direct transport has no remote endpoint; it becomes the final
        // outbound itself, which is what the harness self-test uses.
        let outbounds: [[String: Any]]
        if remoteOutbounds.isEmpty {
            outbounds = [["type": "direct", "tag": "out"]]
        } else {
            var serverOutbounds: [[String: Any]] = []
            for server in remoteOutbounds {
                var outbound: [String: Any] = [
                    "type": server.transport,
                    "tag": server.id.uuidString,
                    "server": server.host,
                    "server_port": server.port,
                ]
                switch server.transport {
                case "trojan":
                    outbound["password"] = server.credentials ?? ""
                case "vless":
                    outbound["uuid"] = server.credentials ?? ""
                    if let flow = server.flow, !flow.isEmpty {
                        outbound["flow"] = flow
                    }
                case "vmess":
                    outbound["uuid"] = server.credentials ?? ""
                    outbound["alter_id"] = server.alterId ?? 0
                    outbound["security"] = server.cipher ?? "auto"
                case "shadowsocks":
                    outbound["password"] = server.credentials ?? ""
                    outbound["method"] = server.cipher ?? "aes-128-gcm"
                case "hysteria2":
                    outbound["password"] = server.credentials ?? ""
                    if let obfs = server.obfs, !obfs.isEmpty {
                        outbound["obfs"] = [
                            "type": obfs,
                            "password": server.obfsPassword ?? "",
                        ]
                    }
                case "tuic":
                    outbound["uuid"] = server.uuid ?? server.credentials ?? ""
                    outbound["password"] = server.credentials ?? ""
                    if let congestion = server.congestionControl, !congestion.isEmpty {
                        outbound["congestion_control"] = congestion
                    }
                default:
                    break
                }
                // These transports ride on TLS by definition; nothing else
                // about the outbound is negotiable without it.
                if server.useTLS || server.transport == "hysteria2" || server.transport == "tuic" {
                    var tls: [String: Any] = ["enabled": true, "server_name": server.serverName ?? server.host]
                    if server.allowInsecure {
                        tls["insecure"] = true
                    }
                    if let alpn = server.alpn, !alpn.isEmpty {
                        tls["alpn"] = alpn.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if let publicKey = server.realityPublicKey, !publicKey.isEmpty {
                        tls["reality"] = [
                            "enabled": true,
                            "public_key": publicKey,
                            "short_id": server.realityShortID ?? "",
                        ]
                        tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
                    }
                    outbound["tls"] = tls
                }
                switch server.network ?? "tcp" {
                case "ws":
                    var transport: [String: Any] = ["type": "ws"]
                    if let path = server.wsPath, !path.isEmpty {
                        transport["path"] = path
                    }
                    if let host = server.wsHost, !host.isEmpty {
                        transport["headers"] = ["Host": host]
                    }
                    outbound["transport"] = transport
                case "grpc":
                    outbound["transport"] = [
                        "type": "grpc",
                        "service_name": server.serviceName ?? "",
                    ]
                default:
                    break
                }
                serverOutbounds.append(outbound)
            }
            // "out" is a selector over every server, so the active endpoint
            // can be switched live (via the command client) without a tunnel
            // restart. The default is the first server, which matches the
            // persistence model of keeping the active server at index 0.
            let selector: [String: Any] = [
                "type": "selector",
                "tag": "out",
                "outbounds": serverOutbounds.map { $0["tag"] as? String ?? "" },
                "default": serverOutbounds.first?["tag"] ?? "",
                "interrupt_exist_connections": true,
            ]
            outbounds = [selector] + serverOutbounds + [["type": "direct", "tag": "direct-out"]]
        }

        let routeRules: [[String: Any]]
        var route: [String: Any] = ["final": "out"]
        switch inbound {
        case .tun(true):
            // DNS hijacking only makes sense in production, where the device
            // DNS servers sit behind the tunnel.
            routeRules = [["protocol": "dns", "action": "hijack-dns"]]
            route["auto_detect_interface"] = true
        case .tun(false):
            // Harness mode: anything addressed to port 53 goes to the
            // engine's own resolver, which queries the on-host test
            // responder from the dns section. Port-based matching needs
            // no sniffing, and this terminating rule must precede the
            // catch-all route rule below.
            routeRules = [
                [
                    "inbound": ["tun-in"],
                    "port": 53,
                    "action": "hijack-dns",
                ],
                [
                    "inbound": ["tun-in"],
                    "action": "route",
                    "outbound": "out",
                    // Test traffic is addressed to the device peer, whose
                    // kernel host route is what hands it to the engine, but
                    // the echo servers live on the host loopback. Rewriting
                    // the dial target to loopback keeps the forward path
                    // on-host; the engine rewrites the reply source back to
                    // the original destination itself.
                    "override_address": "127.0.0.1",
                ],
            ]
            route["auto_detect_interface"] = false
            // Harness mode must reach the on-host echo server over the
            // loopback device; an unpinned dial would follow the test
            // socket's route back into the device we read from. Binding the
            // dialer to lo0 makes local delivery deterministic.
            route["default_interface"] = "lo0"
        case .mixedListener:
            routeRules = []
            route["auto_detect_interface"] = true
        }
        route["rules"] = routeRules

        let logLevel: String
        switch inbound {
        case .tun(let autoRoute): logLevel = autoRoute ? "info" : "debug"
        case .mixedListener: logLevel = "info"
        }

        let json: [String: Any] = [
            "log": ["level": logLevel, "timestamp": true],
            "dns": ["servers": dnsServers],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route,
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
