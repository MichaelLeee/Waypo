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
    func base64SubscriptionBody() {
        let body = """
        trojan://pw@192.0.2.7:443#Alpha
        vless://uuid@192.0.2.8:443?security=tls#Beta
        """
        var encoded = Data(body.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.count % 4 != 0 { encoded.append("=") }
        let servers = ServerImport.parse(encoded)
        #expect(servers.count == 2)
        #expect(servers.map(\.name) == ["Alpha", "Beta"])
    }

    @Test
    func plainTextIsNotMistakenForSubscription() {
        #expect(ServerImport.parse("just some notes\nnothing link-like here").isEmpty)
    }

    @Test
    func vlessWebSocketTransport() {
        let server = ServerImport.parseLine(
            "vless://uuid@w.example.com:443?type=ws&path=%2Fray&host=cdn.example.com&security=tls#WS%20Node"
        )
        #expect(server?.network == "ws")
        #expect(server?.wsPath == "/ray")
        #expect(server?.wsHost == "cdn.example.com")
        #expect(server?.useTLS == true)
    }

    @Test
    func vlessRealityWithFlow() {
        let server = ServerImport.parseLine(
            "vless://uuid@r.example.com:443?security=reality&sni=r.example.com&flow=xtls-rprx-vision&pbk=PUBKEY&sid=abcd#Reality"
        )
        #expect(server?.useTLS == true)
        #expect(server?.realityPublicKey == "PUBKEY")
        #expect(server?.realityShortID == "abcd")
        #expect(server?.flow == "xtls-rprx-vision")
        #expect(server?.serverName == "r.example.com")
    }

    @Test
    func trojanGrpcTransport() {
        let server = ServerImport.parseLine(
            "trojan://pw@g.example.com:443?type=grpc&serviceName=svc#GRPC"
        )
        #expect(server?.network == "grpc")
        #expect(server?.serviceName == "svc")
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

extension ServerImportTests {
    @Test
    func hysteria2Link() {
        let server = ServerImport.parseLine(
            "hysteria2://s3cret@h.example.com:8443/?sni=tls.example.com&obfs=salamander&obfs-password=obSecret#Hy2%20Node"
        )
        #expect(server?.name == "Hy2 Node")
        #expect(server?.host == "h.example.com")
        #expect(server?.port == 8443)
        #expect(server?.transport == "hysteria2")
        #expect(server?.credentials == "s3cret")
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "tls.example.com")
        #expect(server?.obfs == "salamander")
        #expect(server?.obfsPassword == "obSecret")
        #expect(server?.allowInsecure == false)
    }

    @Test
    func hysteria2AliasAndInsecure() {
        let server = ServerImport.parseLine("hy2://pw@192.0.2.9?insecure=1#Loose")
        #expect(server?.transport == "hysteria2")
        #expect(server?.port == 443)
        #expect(server?.credentials == "pw")
        #expect(server?.allowInsecure == true)
        #expect(server?.obfs == nil)
    }

    @Test
    func hysteria2NoneObfsIsCleared() {
        let server = ServerImport.parseLine("hysteria2://pw@192.0.2.10?obfs=none#Plain")
        #expect(server?.obfs == nil)
    }

    @Test
    func tuicLink() {
        let server = ServerImport.parseLine(
            "tuic://11111111-2222-3333-4444-555555555555:q%21w2e3@t.example.com:8443/?sni=tls.example.com&congestion_control=bbr&alpn=h3&udp_relay_mode=native#TUIC%20Node"
        )
        #expect(server?.name == "TUIC Node")
        #expect(server?.host == "t.example.com")
        #expect(server?.port == 8443)
        #expect(server?.transport == "tuic")
        #expect(server?.uuid == "11111111-2222-3333-4444-555555555555")
        #expect(server?.credentials == "q!w2e3")
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "tls.example.com")
        #expect(server?.congestionControl == "bbr")
        #expect(server?.alpn == "h3")
        #expect(server?.allowInsecure == false)
    }

    @Test
    func tuicDefaultsAndInsecure() {
        let server = ServerImport.parseLine(
            "tuic://uuid-goes-here:pw@192.0.2.11?allow_insecure=1#Loose"
        )
        #expect(server?.port == 443)
        #expect(server?.uuid == "uuid-goes-here")
        #expect(server?.credentials == "pw")
        #expect(server?.allowInsecure == true)
        #expect(server?.congestionControl == nil)
        #expect(server?.alpn == nil)
    }

    @Test
    func vmessLinkWithWebSocket() {
        let body: [String: String] = [
            "v": "2", "ps": "VMess Node", "add": "v.example.com", "port": "443",
            "id": "11111111-2222-3333-4444-555555555555", "aid": "0", "scy": "auto",
            "net": "ws", "type": "none", "host": "cdn.example.com", "path": "/ray",
            "tls": "tls", "sni": "v.example.com",
        ]
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
            .data(using: .utf8)!.base64EncodedString()
        let server = ServerImport.parseLine("vmess://\(encoded)")
        #expect(server?.name == "VMess Node")
        #expect(server?.host == "v.example.com")
        #expect(server?.port == 443)
        #expect(server?.transport == "vmess")
        #expect(server?.credentials == "11111111-2222-3333-4444-555555555555")
        #expect(server?.cipher == "auto")
        #expect(server?.alterId == 0)
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "v.example.com")
        #expect(server?.network == "ws")
        #expect(server?.wsPath == "/ray")
        #expect(server?.wsHost == "cdn.example.com")
    }

    @Test
    func vmessNumericFieldsAndPlainTCP() {
        let body: [String: Any] = [
            "ps": "Plain", "add": "192.0.2.12", "port": 10086,
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "aid": 64,
            "net": "tcp",
        ]
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
            .data(using: .utf8)!.base64EncodedString()
        let server = ServerImport.parseLine("vmess://\(encoded)")
        #expect(server?.port == 10086)
        #expect(server?.alterId == 64)
        #expect(server?.cipher == "auto")
        #expect(server?.useTLS == false)
        #expect(server?.network == nil)
    }

    @Test
    func wireGuardLink() {
        // Private key in the link is base64; the parser carries it verbatim.
        let server = ServerImport.parseLine(
            "wireguard://d2ctcHJpdjEy@192.0.2.20:51820/?publickey=PUBKEY&address=10.0.0.2%2F32%2Cfd00%3A%3A2%2F128&presharedkey=PSK&reserved=AQID#WG%20Node"
        )
        #expect(server?.name == "WG Node")
        #expect(server?.host == "192.0.2.20")
        #expect(server?.port == 51820)
        #expect(server?.transport == "wireguard")
        #expect(server?.wgPrivateKey == "d2ctcHJpdjEy")
        #expect(server?.wgPeerPublicKey == "PUBKEY")
        #expect(server?.wgPresharedKey == "PSK")
        #expect(server?.wgAddresses == "10.0.0.2/32, fd00::2/128")
        #expect(server?.wgReserved == "AQID")
    }

    @Test
    func wireGuardLinkDefaults() {
        let server = ServerImport.parseLine("wireguard://key@192.0.2.21?publickey=PUB#WG")
        #expect(server?.port == 51820)
        #expect(server?.wgPresharedKey == nil)
        #expect(server?.wgAddresses == nil)
    }

    @Test
    func anyTLSLink() {
        let server = ServerImport.parseLine(
            "anytls://p%40ss@a.example.com:8443/?sni=sni.example.com&insecure=1&alpn=h2,h3#Any%20Node"
        )
        #expect(server?.name == "Any Node")
        #expect(server?.host == "a.example.com")
        #expect(server?.port == 8443)
        #expect(server?.transport == "anytls")
        #expect(server?.credentials == "p@ss")
        #expect(server?.useTLS == true)
        #expect(server?.serverName == "sni.example.com")
        #expect(server?.allowInsecure == true)
        #expect(server?.alpn == "h2,h3")
    }

    @Test
    func wireGuardQuickConf() throws {
        let conf = """
        [Interface]
        PrivateKey = AbCdEf123456=
        Address = 10.0.0.2/32
        Address = fd00::2/128
        DNS = 1.1.1.1

        [Peer]
        PublicKey = PeerKeyBase64=
        PresharedKey = PskBase64=
        AllowedIPs = 0.0.0.0/0
        Endpoint = peer.example.com:51821
        """
        let servers = ServerImport.parse(conf)
        #expect(servers.count == 1)
        let server = try #require(servers.first)
        #expect(server.name == "WireGuard peer.example.com")
        #expect(server.host == "peer.example.com")
        #expect(server.port == 51821)
        #expect(server.transport == "wireguard")
        #expect(server.wgPrivateKey == "AbCdEf123456=")
        #expect(server.wgAddresses == "10.0.0.2/32, fd00::2/128")
        #expect(server.wgPeerPublicKey == "PeerKeyBase64=")
        #expect(server.wgPresharedKey == "PskBase64=")
    }

    @Test
    func wireGuardQuickConfIPv6EndpointAndDefaultPort() throws {
        let conf = """
        [Interface]
        PrivateKey = k
        Address = 10.0.0.2/32

        [Peer]
        PublicKey = p
        Endpoint = [2001:db8::1]:51820
        """
        let server = try #require(ServerImport.parse(conf).first)
        #expect(server.host == "2001:db8::1")
        #expect(server.port == 51820)
        #expect(server.wgPresharedKey == nil)
    }

    @Test
    func yamlAnyTLSWireGuardAndShadowTLS() {
        let yaml = """
        proxies:
          - name: Any
            type: anytls
            server: 198.51.100.30
            port: 8443
            password: any-pass
            sni: sni.example.com
            skip-cert-verify: true
          - name: WG
            type: wireguard
            server: 198.51.100.31
            port: 51820
            private-key: priv
            public-key: peer
            pre-shared-key: psk
            ip: 10.0.0.2/32
            ipv6: fd00::2/128
            reserved: [1, 2, 3]
          - name: ST
            type: ss
            server: 198.51.100.32
            port: 8443
            cipher: aes-128-gcm
            password: inner-pass
            plugin: shadowtls
            plugin-opts:
              host: st.example.com
              password: st-pass
              version: 3
        """
        let servers = ServerImport.parse(yaml)
        #expect(servers.count == 3)

        let any = servers[0]
        #expect(any.transport == "anytls")
        #expect(any.credentials == "any-pass")
        #expect(any.useTLS == true)
        #expect(any.allowInsecure == true)
        #expect(any.serverName == "sni.example.com")

        let wg = servers[1]
        #expect(wg.transport == "wireguard")
        #expect(wg.wgPrivateKey == "priv")
        #expect(wg.wgPeerPublicKey == "peer")
        #expect(wg.wgPresharedKey == "psk")
        #expect(wg.wgAddresses == "10.0.0.2/32, fd00::2/128")
        #expect(wg.wgReserved == "1,2,3")
        #expect(wg.useTLS == false)

        let st = servers[2]
        #expect(st.transport == "shadowtls")
        #expect(st.host == "st.example.com")
        #expect(st.shadowTLSPassword == "st-pass")
        #expect(st.shadowTLSVersion == 3)
        #expect(st.credentials == "inner-pass")
        #expect(st.cipher == "aes-128-gcm")
        #expect(st.useTLS == false)
    }
}
