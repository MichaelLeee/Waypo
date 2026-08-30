import Foundation
import Testing

@Suite
struct ServerImportTests {
    @Test
    func trojanLink() {
        let server = ServerImport.parseLine(
            "trojan://p%40ss%21@example.com:443?sni=alt.example.com&peer=peer.example.com#My%20Node"
        )
        #expect(server?.name == "My Node")
        #expect(server?.host == "example.com")
        #expect(server?.port == 443)
        #expect(server?.transport == "trojan")
        #expect(server?.credentials == "p@ss!")
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "alt.example.com")
    }

    @Test
    func trojanLinkDefaults() {
        let server = ServerImport.parseLine("trojan://pw@192.0.2.1")
        #expect(server?.port == 443)
        #expect(server?.name == "192.0.2.1")
        #expect(server?.serverName == nil)
    }

    @Test
    func vlessLinkWithTLS() {
        let server = ServerImport.parseLine(
            "vless://11111111-2222-3333-4444-555555555555@v.example.com:2053?type=ws&security=tls&sni=cdn.example.com#VLESS%20Node"
        )
        #expect(server?.name == "VLESS Node")
        #expect(server?.host == "v.example.com")
        #expect(server?.port == 2053)
        #expect(server?.transport == "vless")
        #expect(server?.credentials == "11111111-2222-3333-4444-555555555555")
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "cdn.example.com")
    }

    @Test
    func vlessLinkWithoutSecurity() {
        let server = ServerImport.parseLine("vless://uuid@192.0.2.2:80?security=none#Plain")
        #expect(server?.useTLS == false)
    }

    @Test
    func shadowsocksSIP002() {
        let userInfo = Data("aes-256-gcm:secret".utf8).base64EncodedString()
        let server = ServerImport.parseLine("ss://\(userInfo)@192.0.2.10:8388#SS%20Node")
        #expect(server?.name == "SS Node")
        #expect(server?.host == "192.0.2.10")
        #expect(server?.port == 8388)
        #expect(server?.transport == "shadowsocks")
        #expect(server?.credentials == "secret")
        #expect(server?.cipher == "aes-256-gcm")
        #expect(server?.useTLS == false)
    }

    @Test
    func shadowsocksLegacy() {
        let payload = Data("aes-128-gcm:pw@203.0.113.5:9999".utf8).base64EncodedString()
        let server = ServerImport.parseLine("ss://\(payload)#Legacy")
        #expect(server?.name == "Legacy")
        #expect(server?.host == "203.0.113.5")
        #expect(server?.port == 9999)
        #expect(server?.transport == "shadowsocks")
        #expect(server?.credentials == "pw")
        #expect(server?.cipher == "aes-128-gcm")
    }

    @Test
    func unsupportedScheme() {
        #expect(ServerImport.parseLine("http://example.com") == nil)
        #expect(ServerImport.parseLine("not a link") == nil)
        #expect(ServerImport.parseLine("") == nil)
    }

    @Test
    func multipleLines() {
        let text = """
        trojan://pw@192.0.2.3:443#One
        # a comment line
        not a valid entry

        ss://\(Data("chacha20-ietf-poly1305:k2".utf8).base64EncodedString())@192.0.2.4:443#Two
        """
        let servers = ServerImport.parse(text)
        #expect(servers.count == 2)
        #expect(servers.map(\.name) == ["One", "Two"])
    }

    @Test
    func urlSafeBase64() {
        // Web-safe alphabet and missing padding must both decode.
        var userInfo = Data("aes-128-gcm:aaa+b/c".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while userInfo.count % 4 != 0 { userInfo.removeLast() }
        let server = ServerImport.parseLine("ss://\(userInfo)@192.0.2.6:443#Safe")
        #expect(server?.cipher == "aes-128-gcm")
        #expect(server?.credentials == "aaa+b/c")
    }
}
