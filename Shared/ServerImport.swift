import Foundation

/// Parses share-link entries into configuration values.
/// Supported schemes: trojan, vless, ss (both SIP002 and legacy encodings),
/// hysteria2 (and its hy2 alias), tuic, vmess (base64-JSON body), wireguard,
/// anytls — plus wg-quick configuration text and the community YAML format.
enum ServerImport {
    static func parse(_ text: String) -> [TunnelServer] {
        if text.contains("[Interface]"), let conf = parseWireGuardConf(text) {
            return [conf]
        }
        if looksLikeYAML(text) {
            let parsed = parseYAML(text)
            if !parsed.isEmpty { return parsed }
        }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine($0.trimmingCharacters(in: .whitespaces)) }
        // Subscription endpoints commonly wrap the whole link list in one
        // base64 blob; fall back to decoding it when no raw links are found.
        if lines.isEmpty, let decoded = decodeSubscriptionBody(text) {
            return parse(decoded)
        }
        return lines
    }

    private static func decodeSubscriptionBody(_ text: String) -> String? {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        guard compact.count > 16, !compact.contains("://"),
              compact.allSatisfy({ $0.isLetter || $0.isNumber || "+/=-_".contains($0) }),
              let decoded = base64Decode(compact),
              decoded.contains("://")
        else { return nil }
        return decoded
    }

    static func parseLine(_ line: String) -> TunnelServer? {
        // The body is base64 JSON, not a URL — decode it before URL parsing.
        if line.lowercased().hasPrefix("vmess://") { return parseVMess(line) }
        guard let url = URL(string: line), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "trojan": return parseTrojan(url)
        case "vless": return parseVLESS(url)
        case "ss": return parseShadowsocks(url, rawLine: line)
        case "hysteria2", "hy2": return parseHysteria2(url)
        case "tuic": return parseTUIC(url)
        case "wireguard": return parseWireGuard(url)
        case "anytls": return parseAnyTLS(url)
        default: return nil
        }
    }

    // MARK: - Shared helpers

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == name.lowercased() }?
            .value
    }

    private static func displayName(_ url: URL, fallback: String) -> String {
        if let fragment = url.fragment?.removingPercentEncoding, !fragment.isEmpty {
            return fragment
        }
        return fallback
    }

    private static func decodedUser(_ url: URL) -> String? {
        guard let user = url.user else { return nil }
        return user.removingPercentEncoding ?? user
    }

    private static func decodedPassword(_ url: URL) -> String? {
        guard let password = url.password else { return nil }
        return password.removingPercentEncoding ?? password
    }

    private static func base64Decode(_ value: String) -> String? {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Per-scheme parsers

    /// Hysteria2 links: hysteria2://password@host:port/?sni=...&obfs=salamander&obfs-password=...&insecure=1#name
    /// (the hy2:// scheme is an accepted alias).
    private static func parseHysteria2(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let insecure = ["1", "true"].contains(queryValue("insecure", in: url)?.lowercased())
        let rawObfs = queryValue("obfs", in: url)
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "hysteria2",
            credentials: decodedUser(url),
            useTLS: true,
            serverName: queryValue("sni", in: url),
            obfs: rawObfs?.lowercased() == "none" ? nil : rawObfs,
            obfsPassword: queryValue("obfs-password", in: url) ?? queryValue("obfsPassword", in: url),
            allowInsecure: insecure
        )
    }

    /// TUIC links: tuic://uuid:password@host:port/?sni=...&congestion_control=bbr&alpn=h3&allow_insecure=1#name
    private static func parseTUIC(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let insecure = ["1", "true"].contains(
            (queryValue("allow_insecure", in: url) ?? queryValue("insecure", in: url))?.lowercased())
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "tuic",
            credentials: decodedPassword(url),
            useTLS: true,
            serverName: queryValue("sni", in: url),
            allowInsecure: insecure,
            uuid: decodedUser(url),
            alpn: queryValue("alpn", in: url),
            congestionControl: queryValue("congestion_control", in: url)
                ?? queryValue("congestioncontrol", in: url)
        )
    }

    /// VMess links are not URLs: vmess://<base64 of a JSON object> with the
    /// fields add/port/id/aid/scy/net/path/host/tls/sni/ps. Numeric fields
    /// appear as either strings or numbers depending on the generator.
    private static func parseVMess(_ line: String) -> TunnelServer? {
        guard let decoded = base64Decode(String(line.dropFirst("vmess://".count))),
              let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let host = stringField(json, "add"), !host.isEmpty,
              let id = stringField(json, "id"), !id.isEmpty
        else { return nil }

        let overlay: String?
        switch stringField(json, "net")?.lowercased() {
        case "ws": overlay = "ws"
        case "grpc": overlay = "grpc"
        default: overlay = nil
        }
        let tlsRaw = stringField(json, "tls")?.lowercased()
        let path = stringField(json, "path")
        return TunnelServer(
            name: stringField(json, "ps") ?? host,
            host: host,
            port: intField(json, "port") ?? 443,
            transport: "vmess",
            credentials: id,
            cipher: stringField(json, "scy") ?? "auto",
            useTLS: tlsRaw == "tls" || tlsRaw == "reality",
            serverName: stringField(json, "sni"),
            network: overlay,
            wsPath: overlay == "ws" ? path : nil,
            wsHost: overlay == "ws" ? stringField(json, "host") : nil,
            serviceName: overlay == "grpc" ? path : nil,
            realityPublicKey: tlsRaw == "reality" ? stringField(json, "pbk") : nil,
            realityShortID: tlsRaw == "reality" ? stringField(json, "sid") : nil,
            alterId: intField(json, "aid") ?? 0
        )
    }

    private static func stringField(_ json: [String: Any], _ key: String) -> String? {
        if let value = json[key] as? String { return value }
        if let number = json[key] as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intField(_ json: [String: Any], _ key: String) -> Int? {
        if let number = json[key] as? NSNumber { return number.intValue }
        if let text = json[key] as? String { return Int(text) }
        return nil
    }

    private static func parseTrojan(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "trojan",
            credentials: decodedUser(url),
            useTLS: true,
            serverName: queryValue("sni", in: url) ?? queryValue("peer", in: url),
            network: overlayNetwork(url),
            wsPath: queryValue("path", in: url),
            wsHost: queryValue("host", in: url),
            serviceName: queryValue("serviceName", in: url)
        )
    }

    private static func parseVLESS(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let security = queryValue("security", in: url)?.lowercased()
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "vless",
            credentials: decodedUser(url),
            useTLS: security == "tls" || security == "reality",
            serverName: queryValue("sni", in: url),
            network: overlayNetwork(url),
            wsPath: queryValue("path", in: url),
            wsHost: queryValue("host", in: url),
            serviceName: queryValue("serviceName", in: url),
            flow: queryValue("flow", in: url),
            realityPublicKey: security == "reality" ? queryValue("pbk", in: url) : nil,
            realityShortID: security == "reality" ? queryValue("sid", in: url) : nil
        )
    }

    /// Share links name the overlay network in `type`; "tcp" (or absent)
    /// means plain TCP.
    private static func overlayNetwork(_ url: URL) -> String? {
        guard let type = queryValue("type", in: url)?.lowercased(), type != "tcp" else { return nil }
        return type
    }

    private static func parseShadowsocks(_ url: URL, rawLine: String) -> TunnelServer? {
        if let host = url.host, let port = url.port, let userInfo = decodedUser(url),
           let decoded = base64Decode(userInfo),
           let separator = decoded.firstIndex(of: ":") {
            return TunnelServer(
                name: displayName(url, fallback: host),
                host: host,
                port: port,
                transport: "shadowsocks",
                credentials: String(decoded[decoded.index(after: separator)...]),
                cipher: String(decoded[..<separator])
            )
        }

        // Legacy form: ss://<base64(method:password@host:port)>#name
        let body = rawLine.dropFirst("ss://".count)
        let beforeFragment = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let payload = beforeFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? beforeFragment
        guard let decoded = base64Decode(payload),
              let at = decoded.firstIndex(of: "@"),
              let userInfoColon = decoded[..<at].firstIndex(of: ":")
        else { return nil }
        let hostPortText = String(decoded[decoded.index(after: at)...])
        guard let portColon = hostPortText.lastIndex(of: ":"),
              let port = Int(hostPortText[hostPortText.index(after: portColon)...]) else { return nil }
        return TunnelServer(
            name: displayName(url, fallback: String(hostPortText[..<portColon])),
            host: String(hostPortText[..<portColon]),
            port: port,
            transport: "shadowsocks",
            credentials: String(decoded[decoded.index(after: userInfoColon)..<at]),
            cipher: String(decoded[..<userInfoColon])
        )
    }

    /// WireGuard links: wireguard://<base64 private key>@host:port/?publickey=...&address=10.0.0.2/32,fd00::2/128&presharedkey=...&reserved=...#name
    private static func parseWireGuard(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 51820,
            transport: "wireguard",
            wgPrivateKey: decodedUser(url),
            wgPeerPublicKey: queryValue("publickey", in: url) ?? queryValue("peer", in: url),
            wgPresharedKey: queryValue("presharedkey", in: url),
            wgAddresses: queryValue("address", in: url)?.replacingOccurrences(of: ",", with: ", "),
            wgReserved: queryValue("reserved", in: url)
        )
    }

    /// AnyTLS links: anytls://password@host:port/?sni=...&insecure=1&alpn=...#name
    private static func parseAnyTLS(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let insecure = ["1", "true"].contains(queryValue("insecure", in: url)?.lowercased())
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "anytls",
            credentials: decodedPassword(url) ?? decodedUser(url),
            useTLS: true,
            serverName: queryValue("sni", in: url),
            allowInsecure: insecure,
            alpn: queryValue("alpn", in: url)
        )
    }

    /// wg-quick configuration text with [Interface] and [Peer] sections.
    private static func parseWireGuardConf(_ text: String) -> TunnelServer? {
        var privateKey: String?
        var addresses: [String] = []
        var peerKey: String?
        var presharedKey: String?
        var endpoint: String?
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("[interface]", "privatekey"): privateKey = value
            case ("[interface]", "address"): addresses.append(value)
            case ("[peer]", "publickey"): peerKey = value
            case ("[peer]", "presharedkey"): presharedKey = value
            case ("[peer]", "endpoint"): endpoint = value
            default: break
            }
        }
        guard let privateKey, !privateKey.isEmpty,
              let endpoint, !endpoint.isEmpty
        else { return nil }

        // The endpoint may be host:port or [v6-host]:port.
        var host: String
        var port = 51820
        if let open = endpoint.firstIndex(of: "["), let close = endpoint.firstIndex(of: "]") {
            host = String(endpoint[endpoint.index(after: open)..<close])
            port = Int(String(endpoint[endpoint.index(after: close)...].dropFirst())) ?? 51820
        } else if let colon = endpoint.lastIndex(of: ":") {
            host = String(endpoint[..<colon])
            port = Int(String(endpoint[endpoint.index(after: colon)...])) ?? 51820
        } else {
            host = endpoint
        }
        return TunnelServer(
            name: "WireGuard \(host)",
            host: host,
            port: port,
            transport: "wireguard",
            wgPrivateKey: privateKey,
            wgPeerPublicKey: peerKey,
            wgPresharedKey: presharedKey,
            wgAddresses: addresses.isEmpty ? nil : addresses.joined(separator: ", ")
        )
    }

    // MARK: - Community YAML configuration

    private static func looksLikeYAML(_ text: String) -> Bool {
        // A top-level `proxies:` key at column zero is the community format.
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("proxies:") }
    }

    static func parseYAML(_ text: String) -> [TunnelServer] {
        guard let document = SubscriptionYAML.parseDocument(text),
              let proxies = document["proxies"] as? [[String: Any]]
        else { return [] }
        return proxies.compactMap(server(fromProxy:))
    }

    private static func server(fromProxy proxy: [String: Any]) -> TunnelServer? {
        guard let host = stringField(proxy, "server"), !host.isEmpty,
              let port = intField(proxy, "port"),
              let rawType = stringField(proxy, "type")?.lowercased()
        else { return nil }

        var transport: String
        switch rawType {
        case "ss", "shadowsocks": transport = "shadowsocks"
        case "hysteria2", "hy2": transport = "hysteria2"
        case "trojan", "vless", "vmess", "tuic", "anytls", "wireguard": transport = rawType
        default: return nil
        }

        let overlay = stringField(proxy, "network")?.lowercased()
        let network: String? = overlay == "ws" || overlay == "grpc" ? overlay : nil
        var wsPath: String?
        var wsHost: String?
        if network == "ws", let options = proxy["ws-opts"] as? [String: Any] {
            wsPath = stringField(options, "path")
            if let headers = options["headers"] as? [String: Any] {
                wsHost = stringField(headers, "Host") ?? stringField(headers, "host")
            }
        }
        var serviceName: String?
        if network == "grpc", let options = proxy["grpc-opts"] as? [String: Any] {
            serviceName = stringField(options, "grpc-service-name")
        }

        let alpn: String?
        switch proxy["alpn"] {
        case let values as [Any]:
            let names = values.compactMap(anyString)
            alpn = names.isEmpty ? nil : names.joined(separator: ", ")
        case let single as String:
            alpn = single.isEmpty ? nil : single
        default: alpn = nil
        }

        let reality = proxy["reality-opts"] as? [String: Any]
        let useTLS = boolField(proxy, "tls") || reality != nil
            || transport == "trojan" || transport == "hysteria2" || transport == "tuic"
            || transport == "anytls"

        var obfs = stringField(proxy, "obfs")
        var obfsPassword = stringField(proxy, "obfs-password")
        if stringField(proxy, "plugin")?.lowercased() == "obfs",
           let options = proxy["plugin-opts"] as? [String: Any] {
            obfs = stringField(options, "mode")
            obfsPassword = stringField(options, "password")
        }

        // An ss entry with the shadowtls plugin is a Shadow-TLS endpoint:
        // the plugin password/version describe the outer layer, and the
        // plugin host (when present) is the real endpoint.
        var shadowTLSPassword: String?
        var shadowTLSVersion: Int?
        var resolvedHost = host
        if transport == "shadowsocks", stringField(proxy, "plugin")?.lowercased() == "shadowtls",
           let options = proxy["plugin-opts"] as? [String: Any] {
            transport = "shadowtls"
            shadowTLSPassword = stringField(options, "password")
            shadowTLSVersion = intField(options, "version") ?? 3
            if let pluginHost = stringField(options, "host"), !pluginHost.isEmpty {
                resolvedHost = pluginHost
            }
        }

        var wgPrivateKey: String?
        var wgPeerPublicKey: String?
        var wgPresharedKey: String?
        var wgAddresses: String?
        var wgReserved: String?
        if transport == "wireguard" {
            wgPrivateKey = stringField(proxy, "private-key")
            wgPeerPublicKey = stringField(proxy, "public-key")
            wgPresharedKey = stringField(proxy, "pre-shared-key")
            let interfaceAddresses = [stringField(proxy, "ip"), stringField(proxy, "ipv6")]
                .compactMap { $0 }
            wgAddresses = interfaceAddresses.isEmpty ? nil : interfaceAddresses.joined(separator: ", ")
            if let values = proxy["reserved"] as? [Any] {
                let ints = values.compactMap { ($0 as? NSNumber)?.intValue }
                wgReserved = ints.count == 3 ? ints.map(String.init).joined(separator: ",") : nil
            }
        }

        return TunnelServer(
            name: stringField(proxy, "name") ?? host,
            host: resolvedHost,
            port: port,
            transport: transport,
            credentials: stringField(proxy, "password") ?? stringField(proxy, "uuid"),
            cipher: stringField(proxy, "cipher"),
            useTLS: useTLS,
            serverName: stringField(proxy, "sni") ?? stringField(proxy, "servername")
                ?? stringField(proxy, "server-name"),
            network: network,
            wsPath: wsPath,
            wsHost: wsHost,
            serviceName: serviceName,
            flow: stringField(proxy, "flow"),
            realityPublicKey: reality.flatMap { stringField($0, "public-key") },
            realityShortID: reality.flatMap { stringField($0, "short-id") },
            obfs: obfs,
            obfsPassword: obfsPassword,
            allowInsecure: boolField(proxy, "skip-cert-verify"),
            uuid: stringField(proxy, "uuid"),
            alpn: alpn,
            congestionControl: stringField(proxy, "congestion-controller"),
            alterId: intField(proxy, "alterId"),
            wgPrivateKey: wgPrivateKey,
            wgPeerPublicKey: wgPeerPublicKey,
            wgPresharedKey: wgPresharedKey,
            wgAddresses: wgAddresses,
            wgReserved: wgReserved,
            shadowTLSPassword: shadowTLSPassword,
            shadowTLSVersion: shadowTLSVersion
        )
    }

    private static func anyString(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolField(_ json: [String: Any], _ key: String) -> Bool {
        if let flag = json[key] as? Bool { return flag }
        if let number = json[key] as? NSNumber { return number.boolValue }
        if let text = json[key] as? String { return ["true", "1", "yes"].contains(text.lowercased()) }
        return false
    }
}
