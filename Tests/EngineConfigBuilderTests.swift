import Foundation
import Testing

@Suite
struct EngineConfigBuilderTests {
    private func parse(_ configuration: TunnelConfiguration, inbound: EngineInbound) throws -> [String: Any] {
        let content = try EngineConfigBuilder.makeContent(configuration, inbound: inbound)
        return try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
    }

    @Test
    func mixedListenerInboundShape() throws {
        let json = try parse(TunnelConfiguration.default, inbound: .mixedListener(port: 7219))
        let inbounds = json["inbounds"] as! [[String: Any]]
        #expect(inbounds.count == 1)
        let inbound = inbounds[0]
        #expect(inbound["type"] as? String == "mixed")
        #expect(inbound["listen"] as? String == "127.0.0.1")
        #expect(inbound["listen_port"] as? Int == 7219)
        let route = json["route"] as! [String: Any]
        #expect(route["final"] as? String == "out")
        #expect(route["auto_detect_interface"] as? Bool == true)
        #expect((route["rules"] as! [[String: Any]]).isEmpty)
    }

    @Test
    func tunInboundUsesConfigurationMTU() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443, transport: "trojan", credentials: "pw")],
            mtu: 1420,
            dnsAddresses: ["9.9.9.9"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let inbound = (json["inbounds"] as! [[String: Any]])[0]
        #expect(inbound["type"] as? String == "tun")
        #expect(inbound["mtu"] as? Int == 1420)
        #expect(inbound["auto_route"] as? Bool == true)
        #expect(inbound["dns_mode"] as? String == "hijack")
    }

    @Test
    func harnessTunDisablesRouteManagement() throws {
        let json = try parse(TunnelConfiguration.default, inbound: .tun(autoRoute: false))
        let inbound = (json["inbounds"] as! [[String: Any]])[0]
        #expect(inbound["auto_route"] as? Bool == false)
        #expect(inbound["dns_mode"] as? String == "disabled")
        let route = json["route"] as! [String: Any]
        #expect(route["auto_detect_interface"] as? Bool == false)
        #expect(route["default_interface"] as? String == "lo0")
        // The port-53 DNS hijack must precede the catch-all route rule.
        let rules = route["rules"] as! [[String: Any]]
        #expect(rules.count == 2)
        #expect(rules[0]["port"] as? Int == 53)
        #expect(rules[1]["override_address"] as? String == "127.0.0.1")
    }

    @Test
    func allSixTransportsMapTheirOutboundFields() throws {
        let serverID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(id: serverID, name: "Trojan", host: "198.51.100.1", port: 443,
                             transport: "trojan", credentials: "trojan-pass", useTLS: true),
                TunnelServer(name: "VLESS", host: "198.51.100.2", port: 443,
                             transport: "vless", credentials: "vless-uuid", flow: "xtls-rprx-vision"),
                TunnelServer(name: "VMess", host: "198.51.100.3", port: 443,
                             transport: "vmess", credentials: "vmess-uuid", cipher: "aes-128-gcm", alterId: 0),
                TunnelServer(name: "SS", host: "198.51.100.4", port: 8388,
                             transport: "shadowsocks", credentials: "ss-pass", cipher: "aes-256-gcm"),
                TunnelServer(name: "HY2", host: "198.51.100.5", port: 443,
                             transport: "hysteria2", credentials: "hy2-pass",
                             obfs: "salamander", obfsPassword: "obfs-pass"),
                TunnelServer(name: "TUIC", host: "198.51.100.6", port: 443,
                             transport: "tuic", credentials: "tuic-pass", uuid: "tuic-uuid",
                             congestionControl: "bbr"),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let outbounds = json["outbounds"] as! [[String: Any]]
        let byTag = Dictionary(uniqueKeysWithValues: outbounds.map {
            ($0["tag"] as! String, $0)
        })

        #expect(byTag["trojan-pass"] == nil) // tags are UUIDs, not credentials
        let trojan = byTag[serverID.uuidString]!
        #expect(trojan["type"] as? String == "trojan")
        #expect(trojan["password"] as? String == "trojan-pass")

        let vless = byTag.values.first { $0["type"] as? String == "vless" }!
        #expect(vless["uuid"] as? String == "vless-uuid")
        #expect(vless["flow"] as? String == "xtls-rprx-vision")

        let vmess = byTag.values.first { $0["type"] as? String == "vmess" }!
        #expect(vmess["uuid"] as? String == "vmess-uuid")
        #expect(vmess["security"] as? String == "aes-128-gcm")
        #expect(vmess["alter_id"] as? Int == 0)

        let ss = byTag.values.first { $0["type"] as? String == "shadowsocks" }!
        #expect(ss["password"] as? String == "ss-pass")
        #expect(ss["method"] as? String == "aes-256-gcm")

        let hy2 = byTag.values.first { $0["type"] as? String == "hysteria2" }!
        #expect(hy2["password"] as? String == "hy2-pass")
        let obfs = hy2["obfs"] as! [String: Any]
        #expect(obfs["type"] as? String == "salamander")
        #expect(obfs["password"] as? String == "obfs-pass")
        // QUIC transports ride on TLS by definition.
        #expect((hy2["tls"] as! [String: Any])["enabled"] as? Bool == true)

        let tuic = byTag.values.first { $0["type"] as? String == "tuic" }!
        #expect(tuic["uuid"] as? String == "tuic-uuid")
        #expect(tuic["password"] as? String == "tuic-pass")
        #expect(tuic["congestion_control"] as? String == "bbr")
        #expect((tuic["tls"] as! [String: Any])["enabled"] as? Bool == true)

        // The selector picks up every server tag with the first as default.
        let selector = outbounds.first { $0["tag"] as? String == "out" }!
        let members = selector["outbounds"] as! [String]
        #expect(members.count == 6)
        #expect(selector["default"] as? String == serverID.uuidString)
    }

    @Test
    func realityAndWebSocketAddTheirBlocks() throws {
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(name: "Reality", host: "198.51.100.7", port: 443,
                             transport: "vless", credentials: "uuid-1", useTLS: true,
                             network: "ws", wsPath: "/ws-path", wsHost: "cdn.example.com",
                             realityPublicKey: "pub-key", realityShortID: "0123abcd",
                             alpn: "h2, http/1.1"),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let outbound = (json["outbounds"] as! [[String: Any]])
            .first { $0["type"] as? String == "vless" }!
        let tls = outbound["tls"] as! [String: Any]
        #expect(tls["server_name"] as? String == "198.51.100.7")
        #expect(tls["alpn"] as? [String] == ["h2", "http/1.1"])
        let reality = tls["reality"] as! [String: Any]
        #expect(reality["public_key"] as? String == "pub-key")
        #expect(reality["short_id"] as? String == "0123abcd")
        #expect((tls["utls"] as! [String: Any])["fingerprint"] as? String == "chrome")
        let transport = outbound["transport"] as! [String: Any]
        #expect(transport["type"] as? String == "ws")
        #expect(transport["path"] as? String == "/ws-path")
        #expect((transport["headers"] as! [String: String])["Host"] == "cdn.example.com")
    }

    @Test
    func directOnlyConfigurationBecomesDirectFinal() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "Loop", host: "127.0.0.1", port: 1)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: false))
        let outbounds = json["outbounds"] as! [[String: Any]]
        #expect(outbounds.count == 1)
        #expect(outbounds[0]["type"] as? String == "direct")
        #expect(outbounds[0]["tag"] as? String == "out")
    }
}
