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

        let resolverTags = configuration.dnsResolvers.indices.map { "dns-\($0)" }
        var dnsServers: [[String: Any]] = []
        var dnsRules: [[String: Any]] = []

        // Static answers live in a hosts resolver that matching queries are
        // routed to by rule.
        if !configuration.dnsHosts.isEmpty {
            var predefined: [String: [String]] = [:]
            for host in configuration.dnsHosts where !host.domain.isEmpty && !host.address.isEmpty {
                predefined[host.domain, default: []].append(host.address)
            }
            if !predefined.isEmpty {
                dnsServers.append(["type": "hosts", "tag": "dns-hosts", "predefined": predefined])
                dnsRules.append(["domain": Array(predefined.keys), "server": "dns-hosts"])
            }
        }

        for (index, resolver) in configuration.dnsResolvers.enumerated() {
            var entry: [String: Any] = [
                "type": resolver.kind.rawValue,
                "tag": "dns-\(index)",
                "server": resolver.server,
            ]
            if let port = resolver.serverPort, port > 0 {
                entry["server_port"] = port
            }
            if resolver.kind == .https, let path = resolver.path, !path.isEmpty {
                entry["path"] = path
            }
            // Encrypted transports carry their own TLS settings; the
            // server name doubles as the SNI.
            if resolver.kind != .udp {
                entry["tls"] = ["enabled": true, "server_name": resolver.server]
            }
            dnsServers.append(entry)
        }

        // Fake addresses come from a dedicated resolver; queries for A/AAAA
        // records are routed to it unless the domain is excluded.
        if configuration.fakeIPEnabled, !resolverTags.isEmpty {
            dnsServers.append([
                "type": "fakeip",
                "tag": "dns-fakeip",
                "inet4_range": "198.18.0.0/15",
                "inet6_range": "fc00::/18",
            ])
            let exclusions = configuration.fakeIPExclusions.filter { !$0.isEmpty }
            if !exclusions.isEmpty {
                dnsRules.append(["domain_suffix": exclusions, "server": resolverTags[0]])
            }
            dnsRules.append(["query_type": ["A", "AAAA"], "server": "dns-fakeip"])
        }

        var dns: [String: Any] = ["servers": dnsServers]
        if !dnsRules.isEmpty {
            dns["rules"] = dnsRules
        }
        if let finalTag = resolverTags.first {
            dns["final"] = finalTag
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
            // The tag the top-level selector and groups reference. Most
            // transports are the server's own tag; a Shadow-TLS server emits
            // a second, chained outbound and members point at that one.
            var memberTags: [String] = []
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
                case "anytls":
                    outbound["password"] = server.credentials ?? ""
                case "wireguard":
                    outbound["local_address"] = (server.wgAddresses ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    outbound["private_key"] = server.wgPrivateKey ?? ""
                    outbound["peer_public_key"] = server.wgPeerPublicKey ?? ""
                    if let key = server.wgPresharedKey, !key.isEmpty {
                        outbound["pre_shared_key"] = key
                    }
                    if let reserved = Self.reservedValues(server.wgReserved) {
                        outbound["reserved"] = reserved
                    }
                default:
                    break
                }
                if server.transport == "shadowtls" {
                    // Shadow-TLS wraps an inner Shadowsocks server: the outer
                    // outbound terminates the Shadow-TLS handshake, and the
                    // inner one carries the traffic through it via detour.
                    var tls: [String: Any] = [
                        "enabled": true,
                        "server_name": server.serverName ?? server.host,
                    ]
                    tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
                    outbound["version"] = server.shadowTLSVersion ?? 3
                    outbound["password"] = server.shadowTLSPassword ?? ""
                    outbound["tls"] = tls
                    serverOutbounds.append(outbound)
                    serverOutbounds.append([
                        "type": "shadowsocks",
                        "tag": server.id.uuidString + "-inner",
                        "server": server.host,
                        "server_port": server.port,
                        "method": server.cipher ?? "aes-128-gcm",
                        "password": server.credentials ?? "",
                        "detour": server.id.uuidString,
                    ])
                    memberTags.append(server.id.uuidString + "-inner")
                    continue
                }
                // These transports ride on TLS by definition; nothing else
                // about the outbound is negotiable without it.
                if server.useTLS || server.transport == "hysteria2" || server.transport == "tuic"
                    || server.transport == "anytls" {
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
                memberTags.append(server.id.uuidString)
            }
            let tagByMemberID = Dictionary(
                uniqueKeysWithValues: zip(remoteOutbounds.map(\.id), memberTags)
            )
            // Groups sit between the leaf server outbounds and "out": each
            // is a selector or url-test over its member servers, and "out"
            // can route to any group as a whole.
            var groupOutbounds: [[String: Any]] = []
            for group in configuration.groups {
                let groupMemberTags = group.memberIDs.compactMap { tagByMemberID[$0] }
                guard !groupMemberTags.isEmpty else { continue }
                var outbound: [String: Any] = [
                    "type": group.kind == .urlTest ? "urltest" : "selector",
                    "tag": group.id.uuidString,
                    "outbounds": groupMemberTags,
                ]
                switch group.kind {
                case .select:
                    // The persisted selection is the group's first member,
                    // matching how the selection is kept at index 0 of the
                    // member list.
                    outbound["default"] = groupMemberTags[0]
                    outbound["interrupt_exist_connections"] = true
                case .urlTest:
                    outbound["url"] = group.url
                    // The engine expects a duration string; a bare number
                    // would be interpreted as nanoseconds.
                    outbound["interval"] = "\(Int(group.interval))s"
                    outbound["tolerance"] = 50
                }
                groupOutbounds.append(outbound)
            }
            // "out" is a selector over every group and server, so the active
            // endpoint can be switched live (via the command client) without
            // a tunnel restart. The default is the first server, which
            // matches the persistence model of keeping the active server at
            // index 0.
            let selector: [String: Any] = [
                "type": "selector",
                "tag": "out",
                "outbounds": groupOutbounds.map { $0["tag"] as? String ?? "" } + memberTags,
                "default": memberTags.first ?? "",
                "interrupt_exist_connections": true,
            ]
            outbounds = [selector] + groupOutbounds + serverOutbounds + [["type": "direct", "tag": "direct-out"]]
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
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route,
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The engine wants the three-byte header as a JSON int array; sources
    /// give it either as comma-separated numbers or as base64 of the bytes.
    private static func reservedValues(_ text: String?) -> [Int]? {
        guard let text, !text.isEmpty else { return nil }
        if text.contains(",") {
            let values = text.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            return values.count == 3 ? values : nil
        }
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count == 3 else { return nil }
        return data.map(Int.init)
    }
}
