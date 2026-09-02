import Foundation

/// Parses share-link entries into configuration values.
/// Supported schemes: trojan, vless, ss (both SIP002 and legacy encodings),
/// hysteria2 (and its hy2 alias), tuic.
enum ServerImport {
    static func parse(_ text: String) -> [TunnelServer] {
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
        guard let url = URL(string: line), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "trojan": return parseTrojan(url)
        case "vless": return parseVLESS(url)
        case "ss": return parseShadowsocks(url, rawLine: line)
        case "hysteria2", "hy2": return parseHysteria2(url)
        case "tuic": return parseTUIC(url)
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
            alpn: queryValue("alpn", in: url),
            congestionControl: queryValue("congestion_control", in: url)
                ?? queryValue("congestioncontrol", in: url),
            allowInsecure: insecure,
            uuid: decodedUser(url)
        )
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
}
