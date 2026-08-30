import Foundation

/// Parses share-link entries into configuration values.
/// Supported schemes: trojan, vless, ss (both SIP002 and legacy encodings).
enum ServerImport {
    static func parse(_ text: String) -> [TunnelServer] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func parseLine(_ line: String) -> TunnelServer? {
        guard let url = URL(string: line), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "trojan": return parseTrojan(url)
        case "vless": return parseVLESS(url)
        case "ss": return parseShadowsocks(url, rawLine: line)
        default: return nil
        }
    }

    // MARK: - Shared helpers

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == name }?
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

    private static func parseTrojan(_ url: URL) -> TunnelServer? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return TunnelServer(
            name: displayName(url, fallback: host),
            host: host,
            port: url.port ?? 443,
            transport: "trojan",
            credentials: decodedUser(url),
            useTLS: true,
            serverName: queryValue("sni", in: url) ?? queryValue("peer", in: url)
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
            serverName: queryValue("sni", in: url)
        )
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
