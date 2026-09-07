import Foundation
import Testing

@Suite
struct SubscriptionYAMLTests {
    @Test
    func parserHandlesNestedBlocksFlowAndScalars() throws {
        let document = """
        # leading comment
        port: 7890
        mode: rule
        tun:
          enable: true
          stack: system
        proxies:
          - name: "first"
            port: 443
            tags: [a, b, c]
            nested:
              path: /p
              headers:
                Host: cdn.example.com
          - {name: second, port: 8388, flag: true}
        """
        let parsed = SubscriptionYAML.parseDocument(document)
        #expect(parsed != nil)
        #expect(parsed?["port"] as? Int == 7890)
        #expect(parsed?["mode"] as? String == "rule")
        let tun = parsed?["tun"] as! [String: Any]
        #expect(tun["enable"] as? Bool == true)
        #expect(tun["stack"] as? String == "system")
        let proxies = parsed?["proxies"] as! [[String: Any]]
        #expect(proxies.count == 2)
        #expect(proxies[0]["name"] as? String == "first")
        let nested = proxies[0]["nested"] as! [String: Any]
        #expect(nested["path"] as? String == "/p")
        let headers = nested["headers"] as! [String: Any]
        #expect(headers["Host"] as? String == "cdn.example.com")
        #expect((proxies[0]["tags"] as! [Any]).count == 3)
        #expect(proxies[1]["name"] as? String == "second")
        #expect(proxies[1]["port"] as? Int == 8388)
        #expect(proxies[1]["flag"] as? Bool == true)
    }

    @Test
    func quotedAndEdgeScalarsKeepTheirTypes() throws {
        let document = """
        a: "0123abcd"
        b: 'single: quoted'
        c: null
        d: 0721
        e: "with \\"escape\\"" # trailing comment
        """
        let parsed = SubscriptionYAML.parseDocument(document)!
        #expect(parsed["a"] as? String == "0123abcd")
        #expect(parsed["b"] as? String == "single: quoted")
        #expect(parsed["c"] as? NSNull != nil)
        #expect(parsed["e"] as? String == "with \"escape\"")
    }

    @Test
    func importsAllTransportsFromYAML() throws {
        let document = """
        port: 7890
        log-level: info

        proxies:
          - name: edge-trojan
            type: trojan
            server: 198.51.100.1
            port: 443
            password: secret
            sni: example.com
            skip-cert-verify: true
            network: ws
            ws-opts:
              path: /wspath
              headers:
                Host: cdn.example.com
          - {name: edge-ss, type: ss, server: 198.51.100.2, port: 8388, cipher: aes-256-gcm, password: sspass}
          - name: edge-vless
            type: vless
            server: 198.51.100.3
            port: 443
            uuid: vless-uuid
            flow: xtls-rprx-vision
            tls: true
            servername: vless.example.com
            reality-opts:
              public-key: pbk-value
              short-id: "0123abcd"
          - name: edge-hy2
            type: hysteria2
            server: 198.51.100.4
            port: 443
            password: hy2pass
            obfs: salamander
            obfs-password: obfspass
            alpn:
              - h3
          - name: edge-tuic
            type: tuic
            server: 198.51.100.5
            port: 443
            uuid: tuic-uuid
            password: tuicpass
            congestion-controller: bbr
            sni: tuic.example.com
          - name: edge-vmess
            type: vmess
            server: 198.51.100.6
            port: 443
            uuid: vmess-uuid
            alterId: 0
            cipher: aes-128-gcm
            tls: true
            servername: vmess.example.com
        """
        let servers = ServerImport.parse(document)
        #expect(servers.count == 6)
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })

        let trojan = byName["edge-trojan"]!
        #expect(trojan.transport == "trojan")
        #expect(trojan.credentials == "secret")
        #expect(trojan.useTLS)
        #expect(trojan.serverName == "example.com")
        #expect(trojan.allowInsecure)
        #expect(trojan.network == "ws")
        #expect(trojan.wsPath == "/wspath")
        #expect(trojan.wsHost == "cdn.example.com")

        let ss = byName["edge-ss"]!
        #expect(ss.transport == "shadowsocks")
        #expect(ss.cipher == "aes-256-gcm")
        #expect(ss.credentials == "sspass")

        let vless = byName["edge-vless"]!
        #expect(vless.transport == "vless")
        #expect(vless.credentials == "vless-uuid")
        #expect(vless.flow == "xtls-rprx-vision")
        #expect(vless.useTLS)
        #expect(vless.serverName == "vless.example.com")
        #expect(vless.realityPublicKey == "pbk-value")
        #expect(vless.realityShortID == "0123abcd")

        let hy2 = byName["edge-hy2"]!
        #expect(hy2.transport == "hysteria2")
        #expect(hy2.useTLS)
        #expect(hy2.obfs == "salamander")
        #expect(hy2.obfsPassword == "obfspass")
        #expect(hy2.alpn == "h3")

        let tuic = byName["edge-tuic"]!
        #expect(tuic.transport == "tuic")
        #expect(tuic.uuid == "tuic-uuid")
        #expect(tuic.credentials == "tuicpass")
        #expect(tuic.congestionControl == "bbr")

        let vmess = byName["edge-vmess"]!
        #expect(vmess.transport == "vmess")
        #expect(vmess.credentials == "vmess-uuid")
        #expect(vmess.cipher == "aes-128-gcm")
        #expect(vmess.alterId == 0)
        #expect(vmess.useTLS)
    }

    @Test
    func skipsUnknownTypesAndKeepsShareLinkParsingUnaffected() {
        let document = """
        proxies:
          - name: known
            type: ss
            server: 198.51.100.9
            port: 8388
            cipher: aes-256-gcm
            password: p
          - name: unknown
            type: mieru
            server: 198.51.100.10
            port: 443
        """
        let servers = ServerImport.parse(document)
        #expect(servers.count == 1)
        #expect(servers[0].name == "known")

        let links = "trojan://secret@198.51.100.1:443#linked"
        let parsed = ServerImport.parse(links)
        #expect(parsed.count == 1)
        #expect(parsed[0].transport == "trojan")
    }
}
