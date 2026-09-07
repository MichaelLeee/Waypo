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
        // Without user rules, sniffing is the only production rule.
        let rules = route["rules"] as! [[String: Any]]
        #expect(rules.count == 1)
        #expect(rules[0]["action"] as? String == "sniff")
        #expect(route["rule_set"] == nil)
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

    @Test
    func groupsEmitAndJoinTheTopSelector() throws {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let urlTestGroupID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let selectGroupID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(id: a, name: "A", host: "198.51.100.1", port: 443,
                             transport: "trojan", credentials: "pa"),
                TunnelServer(id: b, name: "B", host: "198.51.100.2", port: 443,
                             transport: "trojan", credentials: "pb"),
                TunnelServer(id: c, name: "C", host: "198.51.100.3", port: 443,
                             transport: "trojan", credentials: "pc"),
            ],
            groups: [
                PolicyGroup(id: urlTestGroupID, name: "Fastest", kind: .urlTest,
                            memberIDs: [a, b], interval: 60),
                PolicyGroup(id: selectGroupID, name: "Pick", kind: .select, memberIDs: [b, c]),
                // Every member was deleted; the group must not be emitted.
                PolicyGroup(name: "Empty", kind: .select, memberIDs: [UUID()]),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let outbounds = json["outbounds"] as! [[String: Any]]
        let byTag = Dictionary(uniqueKeysWithValues: outbounds.map { ($0["tag"] as! String, $0) })

        let urlTest = byTag[urlTestGroupID.uuidString]!
        #expect(urlTest["type"] as? String == "urltest")
        #expect(urlTest["outbounds"] as? [String] == [a.uuidString, b.uuidString])
        #expect(urlTest["interval"] as? String == "60s")
        #expect(urlTest["tolerance"] as? Int == 50)
        #expect(urlTest["url"] != nil)

        let select = byTag[selectGroupID.uuidString]!
        #expect(select["type"] as? String == "selector")
        #expect(select["outbounds"] as? [String] == [b.uuidString, c.uuidString])
        #expect(select["default"] as? String == b.uuidString)
        #expect(select["interrupt_exist_connections"] as? Bool == true)

        let selector = outbounds.first { $0["tag"] as? String == "out" }!
        #expect(selector["outbounds"] as? [String] ==
                [urlTestGroupID.uuidString, selectGroupID.uuidString, a.uuidString, b.uuidString, c.uuidString])
        #expect(selector["default"] as? String == a.uuidString)

        // Order: selector, then groups, then leaf servers.
        let tags = outbounds.map { $0["tag"] as! String }
        #expect(tags == ["out", urlTestGroupID.uuidString, selectGroupID.uuidString,
                         a.uuidString, b.uuidString, c.uuidString, "direct-out"])
    }

    @Test
    func wireGuardAnyTLSAndShadowTLSMapTheirOutboundFields() throws {
        let wgID = UUID(uuidString: "11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let anyID = UUID(uuidString: "22222222-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let stID = UUID(uuidString: "33333333-cccc-cccc-cccc-cccccccccccc")!
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(id: wgID, name: "WG", host: "198.51.100.10", port: 51820,
                             transport: "wireguard",
                             wgPrivateKey: "wg-priv", wgPeerPublicKey: "wg-peer",
                             wgPresharedKey: "wg-psk",
                             wgAddresses: "10.0.0.2/32, fd00::2/128",
                             wgReserved: "AQID"),
                TunnelServer(id: anyID, name: "Any", host: "198.51.100.11", port: 8443,
                             transport: "anytls", credentials: "any-pass"),
                TunnelServer(id: stID, name: "ST", host: "198.51.100.12", port: 8443,
                             transport: "shadowtls", credentials: "inner-pass",
                             cipher: "aes-128-gcm", serverName: "st.example.com",
                             shadowTLSPassword: "st-pass"),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let outbounds = json["outbounds"] as! [[String: Any]]
        let byTag = Dictionary(uniqueKeysWithValues: outbounds.map { ($0["tag"] as! String, $0) })

        let wg = byTag[wgID.uuidString]!
        #expect(wg["type"] as? String == "wireguard")
        #expect(wg["local_address"] as? [String] == ["10.0.0.2/32", "fd00::2/128"])
        #expect(wg["private_key"] as? String == "wg-priv")
        #expect(wg["peer_public_key"] as? String == "wg-peer")
        #expect(wg["pre_shared_key"] as? String == "wg-psk")
        // Base64 "AQID" decodes to the three bytes 1, 2, 3.
        #expect(wg["reserved"] as? [Int] == [1, 2, 3])
        #expect(wg["tls"] == nil)

        let any = byTag[anyID.uuidString]!
        #expect(any["type"] as? String == "anytls")
        #expect(any["password"] as? String == "any-pass")
        // AnyTLS rides on TLS even when the toggle is off.
        #expect((any["tls"] as! [String: Any])["enabled"] as? Bool == true)

        let outer = byTag[stID.uuidString]!
        #expect(outer["type"] as? String == "shadowtls")
        #expect(outer["version"] as? Int == 3)
        #expect(outer["password"] as? String == "st-pass")
        let tls = outer["tls"] as! [String: Any]
        #expect(tls["server_name"] as? String == "st.example.com")
        #expect((tls["utls"] as! [String: Any])["fingerprint"] as? String == "chrome")

        // The inner Shadowsocks outbound is chained through the outer one,
        // and group members point at that usable leg.
        let innerTag = stID.uuidString + "-inner"
        let inner = byTag[innerTag]!
        #expect(inner["type"] as? String == "shadowsocks")
        #expect(inner["method"] as? String == "aes-128-gcm")
        #expect(inner["password"] as? String == "inner-pass")
        #expect(inner["detour"] as? String == stID.uuidString)

        let selector = outbounds.first { $0["tag"] as? String == "out" }!
        #expect(selector["outbounds"] as? [String] ==
                [wgID.uuidString, anyID.uuidString, innerTag])
        #expect(selector["default"] as? String == wgID.uuidString)
    }

    @Test
    func wireGuardReservedAcceptsCommaSeparatedInts() throws {
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(name: "WG", host: "198.51.100.13", port: 51820,
                             transport: "wireguard",
                             wgPrivateKey: "priv", wgPeerPublicKey: "peer",
                             wgAddresses: "10.0.0.2/32", wgReserved: "7, 8, 9"),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let wg = (json["outbounds"] as! [[String: Any]]).first { $0["type"] as? String == "wireguard" }!
        #expect(wg["reserved"] as? [Int] == [7, 8, 9])
    }

    @Test
    func plainResolversEmitUDPServersWithFinalAndNoRules() throws {
        let json = try parse(TunnelConfiguration.default, inbound: .tun(autoRoute: true))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        #expect(servers.count == 2)
        #expect(servers[0]["type"] as? String == "udp")
        #expect(servers[0]["tag"] as? String == "dns-0")
        #expect(servers[0]["server"] as? String == "1.1.1.1")
        #expect(servers[1]["server"] as? String == "8.8.8.8")
        #expect(dns["final"] as? String == "dns-0")
        #expect(dns["rules"] == nil)
    }

    @Test
    func encryptedResolversCarryPortPathAndTLS() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsResolvers: [
                DNSResolver(kind: .https, server: "doh.example.com", serverPort: 8443, path: "/custom"),
                DNSResolver(kind: .tls, server: "dot.example.com"),
                DNSResolver(kind: .quic, server: "doq.example.com"),
            ]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let servers = (json["dns"] as! [String: Any])["servers"] as! [[String: Any]]
        #expect(servers.count == 3)

        let doh = servers[0]
        #expect(doh["type"] as? String == "https")
        #expect(doh["server_port"] as? Int == 8443)
        #expect(doh["path"] as? String == "/custom")
        let dohTLS = doh["tls"] as! [String: Any]
        #expect(dohTLS["enabled"] as? Bool == true)
        #expect(dohTLS["server_name"] as? String == "doh.example.com")

        let dot = servers[1]
        #expect(dot["type"] as? String == "tls")
        #expect(dot["path"] == nil)
        let dotTLS = dot["tls"] as! [String: Any]
        #expect(dotTLS["enabled"] as? Bool == true)
        #expect(dotTLS["server_name"] as? String == "dot.example.com")

        let doq = servers[2]
        #expect(doq["type"] as? String == "quic")
        #expect((doq["tls"] as! [String: Any])["enabled"] as? Bool == true)

        // The plain-UDP-only fields stay off encrypted resolvers.
        #expect(doh["server_port"] as? Int == 8443)
        #expect(dot["server_port"] == nil)
    }

    @Test
    func hostsEmitPredefinedServerAndDomainRule() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsResolvers: [DNSResolver(server: "1.1.1.1")],
            dnsHosts: [
                DNSHostMapping(domain: "home.lan", address: "192.168.1.10"),
                DNSHostMapping(domain: "nas.lan", address: "192.168.1.20"),
            ]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        // The hosts resolver precedes the regular ones and gets its own tag.
        #expect(servers.count == 2)
        let hosts = servers.first { $0["tag"] as? String == "dns-hosts" }!
        #expect(hosts["type"] as? String == "hosts")
        #expect((hosts["predefined"] as! [String: [String]])["home.lan"] == ["192.168.1.10"])

        let rules = dns["rules"] as! [[String: Any]]
        #expect(rules.count == 1)
        #expect(rules[0]["domain"] as? [String] == ["home.lan", "nas.lan"])
        #expect(rules[0]["server"] as? String == "dns-hosts")
        #expect(dns["final"] as? String == "dns-0")
    }

    @Test
    func fakeIPRoutesAAndAAAAQueriesWithExclusions() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsResolvers: [DNSResolver(server: "1.1.1.1")],
            fakeIPEnabled: true,
            fakeIPExclusions: ["company.lan", "internal.corp"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        let fakeIP = servers.first { $0["tag"] as? String == "dns-fakeip" }!
        #expect(fakeIP["type"] as? String == "fakeip")
        #expect(fakeIP["inet4_range"] as? String == "198.18.0.0/15")
        #expect(fakeIP["inet6_range"] as? String == "fc00::/18")

        let rules = dns["rules"] as! [[String: Any]]
        // Exclusions first, then the terminating fake-answer rule.
        #expect(rules.count == 2)
        #expect(rules[0]["domain_suffix"] as? [String] == ["company.lan", "internal.corp"])
        #expect(rules[0]["server"] as? String == "dns-0")
        #expect(rules[1]["query_type"] as? [String] == ["A", "AAAA"])
        #expect(rules[1]["server"] as? String == "dns-fakeip")
    }

    @Test
    func fakeIPWithoutResolversIsSkipped() throws {
        // A configuration always carries at least one resolver, but the
        // builder must not crash on an empty list either way.
        var config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsResolvers: []
        )
        config.fakeIPEnabled = true
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        #expect(servers.isEmpty)
        #expect(dns["rules"] == nil)
        #expect(dns["final"] == nil)
    }

    @Test
    func userRulesEmitInOrderAfterSniffAndDNSHijack() throws {
        let serverID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
        let config = TunnelConfiguration(
            servers: [TunnelServer(id: serverID, name: "A", host: "198.51.100.1", port: 443,
                                   transport: "trojan", credentials: "pw")],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"],
            rules: [
                RoutingRule(domains: ["ads.example.com"], ports: [80, 443],
                            action: .route, outboundID: serverID),
                RoutingRule(domainSuffixes: ["blocked.example"], invert: true, action: .reject),
                RoutingRule(ipCIDRs: ["10.0.0.0/8"], action: .direct),
            ]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let rules = (json["route"] as! [String: Any])["rules"] as! [[String: Any]]
        // Sniff, then DNS hijack, then the user's rules in order.
        #expect(rules.count == 5)
        #expect(rules[0]["action"] as? String == "sniff")
        #expect(rules[1]["action"] as? String == "hijack-dns")

        #expect(rules[2]["outbound"] as? String == serverID.uuidString)
        #expect(rules[2]["domain"] as? [String] == ["ads.example.com"])
        #expect(rules[2]["port"] as? [Int] == [80, 443])

        #expect(rules[3]["action"] as? String == "reject")
        #expect(rules[3]["domain_suffix"] as? [String] == ["blocked.example"])
        #expect(rules[3]["invert"] as? Bool == true)

        #expect(rules[4]["action"] as? String == "direct")
        #expect(rules[4]["ip_cidr"] as? [String] == ["10.0.0.0/8"])
    }

    @Test
    func routelessRulesTargetTheTopSelector() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"],
            rules: [RoutingRule(domainKeywords: ["banking"])]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let rules = (json["route"] as! [String: Any])["rules"] as! [[String: Any]]
        let last = rules.last!
        #expect(last["outbound"] as? String == "out")
        #expect(last["domain_keyword"] as? [String] == ["banking"])
    }

    @Test
    func remoteRuleSetsEmitWithTagsAndFormats() throws {
        let setA = RemoteRuleSet(id: UUID(uuidString: "11111111-bbbb-cccc-dddd-000000000001")!,
                                 name: "Ads", url: "https://example.com/ads.json")
        let setB = RemoteRuleSet(id: UUID(uuidString: "11111111-bbbb-cccc-dddd-000000000002")!,
                                 name: "Regions", url: "https://example.com/geo.srs",
                                 updateInterval: 43200)
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"],
            rules: [RoutingRule(ruleSetTags: [setA.id.uuidString], action: .reject)],
            ruleSets: [setA, setB]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let route = json["route"] as! [String: Any]
        let sets = route["rule_set"] as! [[String: Any]]
        #expect(sets.count == 2)
        #expect(sets[0]["type"] as? String == "remote")
        #expect(sets[0]["tag"] as? String == setA.id.uuidString)
        #expect(sets[0]["url"] as? String == "https://example.com/ads.json")
        #expect(sets[0]["format"] as? String == "source")
        #expect(sets[0]["update_interval"] as? String == "86400s")
        #expect(sets[1]["format"] as? String == "binary")
        #expect(sets[1]["update_interval"] as? String == "43200s")

        let rules = route["rules"] as! [[String: Any]]
        #expect(rules.last!["rule_set"] as? [String] == [setA.id.uuidString])
    }

    @Test
    func harnessModeIgnoresUserRules() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"],
            rules: [RoutingRule(domainSuffixes: ["example.com"], action: .reject)],
            ruleSets: [RemoteRuleSet(name: "X", url: "https://example.com/x.json")]
        )
        let json = try parse(config, inbound: .tun(autoRoute: false))
        let route = json["route"] as! [String: Any]
        let rules = route["rules"] as! [[String: Any]]
        // Only the harness's own port-53 hijack and catch-all route rules.
        #expect(rules.count == 2)
        #expect(route["rule_set"] == nil)
    }

    @Test
    func emptyAndBlankRulesAreSkipped() throws {
        var config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        config.rules = [RoutingRule(), RoutingRule(invert: true)]
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let rules = (json["route"] as! [String: Any])["rules"] as! [[String: Any]]
        #expect(rules.count == 2) // sniff + hijack-dns only
    }

    @Test
    func wireGuardWithoutOptionalFieldsOmitsTheirKeys() throws {
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(name: "WG", host: "198.51.100.14", port: 51820,
                             transport: "wireguard",
                             wgPrivateKey: "priv", wgPeerPublicKey: "peer",
                             wgAddresses: "10.0.0.2/32"),
            ],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        )
        let json = try parse(config, inbound: .tun(autoRoute: true))
        let wg = (json["outbounds"] as! [[String: Any]]).first { $0["type"] as? String == "wireguard" }!
        #expect(wg["pre_shared_key"] == nil)
        #expect(wg["reserved"] == nil)
    }
}
