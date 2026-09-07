import Foundation
import NetworkExtension
import Testing

@Suite
struct TunnelConfigurationTests {
    @Test
    func serverRoundTripPreservesAllFields() throws {
        let server = TunnelServer(
            name: "Full",
            host: "203.0.113.7",
            port: 8443,
            transport: "trojan",
            credentials: "secret",
            cipher: nil,
            useTLS: true,
            serverName: "sni.example.com"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(TunnelServer.self, from: data)
        #expect(decoded == server)
    }

    @Test
    func decodeFillsOptionalDefaults() throws {
        let json = #"{"name":"Min","host":"198.51.100.1","port":443}"#
        let server = try JSONDecoder().decode(
            TunnelServer.self,
            from: Data(json.utf8)
        )
        #expect(server.transport == "direct")
        #expect(server.useTLS == false)
        #expect(server.credentials == nil)
        #expect(server.cipher == nil)
        #expect(server.serverName == nil)
    }

    @Test
    func decodeWithoutIDGeneratesOne() throws {
        let json = #"{"name":"A","host":"198.51.100.2","port":1}"#
        let server = try JSONDecoder().decode(
            TunnelServer.self,
            from: Data(json.utf8)
        )
        #expect(server.id != UUID())
    }

    @Test
    func decodePreservesExistingID() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"A","host":"h","port":1}"#
        let server = try JSONDecoder().decode(
            TunnelServer.self,
            from: Data(json.utf8)
        )
        #expect(server.id == id)
    }

    @Test
    func configurationRoundTrip() throws {
        let config = TunnelConfiguration(
            servers: [
                TunnelServer(name: "One", host: "198.51.100.3", port: 443, transport: "trojan",
                             credentials: "pw", useTLS: true),
                TunnelServer(name: "Two", host: "198.51.100.4", port: 80),
            ],
            mtu: 1420,
            dnsAddresses: ["9.9.9.9"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test
    func storeRoundTrip() throws {
        let suite = "test.waypo.store.roundtrip"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "Stored", host: "198.51.100.5", port: 8388,
                                   transport: "shadowsocks", credentials: "pw",
                                   cipher: "aes-256-gcm")],
            mtu: 9000,
            dnsAddresses: ["1.0.0.1"]
        )
        try store.saveConfiguration(config)
        #expect(store.loadConfiguration() == config)
    }

    @Test
    func storeReturnsDefaultWhenEmpty() throws {
        let suite = "test.waypo.store.empty"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        #expect(store.loadConfiguration() == TunnelConfiguration.default)
    }

    @Test
    func profileSetRoundTrip() throws {
        let suite = "test.waypo.store.profiles"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let home = TunnelProfile(name: "Home", configuration: TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.6", port: 443)],
            mtu: 1500,
            dnsAddresses: ["1.1.1.1"]
        ))
        let travel = TunnelProfile(name: "Travel")
        try store.saveProfileSet(ProfileSet(profiles: [home, travel], activeProfileID: travel.id))

        let loaded = store.loadProfileSet()
        #expect(loaded.profiles.count == 2)
        #expect(loaded.activeProfileID == travel.id)
        #expect(loaded.activeProfile?.name == "Travel")
        // The active profile is mirrored into the single-configuration key
        // the provider extension reads.
        #expect(store.loadConfiguration() == travel.configuration)
    }

    @Test
    func legacyConfigurationMigratesToDefaultProfile() throws {
        let suite = "test.waypo.store.migration"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "Legacy", host: "198.51.100.7", port: 8443)],
            mtu: 1500,
            dnsAddresses: ["8.8.8.8"]
        )
        try store.saveConfiguration(config)

        let set = store.loadProfileSet()
        #expect(set.profiles.count == 1)
        #expect(set.profiles.first?.name == "Default")
        #expect(set.profiles.first?.configuration == config)
        #expect(set.activeProfile?.configuration == config)
    }

    @Test
    @MainActor
    func controllerSwitchesAndPersistsProfiles() throws {
        let suite = "test.waypo.controller.profiles"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()
        #expect(controller.activeProfile?.name == "Default")

        let id = controller.addProfile(named: "  Second  ")
        #expect(id != nil)
        controller.switchProfile(to: id!)
        #expect(controller.activeProfile?.name == "Second")
        #expect(controller.configuration.servers.isEmpty)

        controller.addServer(TunnelServer(name: "S", host: "198.51.100.8", port: 443))
        #expect(controller.configuration.servers.count == 1)

        // Re-reading from the store keeps Second active with its server.
        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.activeProfile?.name == "Second")
        #expect(reloaded.configuration.servers.count == 1)

        reloaded.deleteActiveProfile()
        #expect(reloaded.activeProfile?.name == "Default")
        #expect(reloaded.profiles.count == 1)
    }

    @Test
    func newTransportFieldsRoundTrip() throws {
        let server = TunnelServer(
            name: "New",
            host: "198.51.100.9",
            port: 51820,
            transport: "wireguard",
            credentials: "unused",
            wgPrivateKey: "priv",
            wgPeerPublicKey: "peer",
            wgPresharedKey: "psk",
            wgAddresses: "10.0.0.2/32, fd00::2/128",
            wgReserved: "1,2,3",
            shadowTLSPassword: "st-pass",
            shadowTLSVersion: 2
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(TunnelServer.self, from: data)
        #expect(decoded == server)
    }

    @Test
    func decodeWithoutGroupsKeepsEmptyList() throws {
        // Configurations persisted before groups existed must still load.
        let json = #"{"servers":[],"mtu":1500,"dnsAddresses":["1.1.1.1"]}"#
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: Data(json.utf8))
        #expect(decoded.groups.isEmpty)
    }

    @Test
    func dnsSettingsRoundTrip() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            dnsResolvers: [
                DNSResolver(kind: .udp, server: "1.1.1.1"),
                DNSResolver(kind: .https, server: "doh.example.com", path: "/dns-query"),
                DNSResolver(kind: .tls, server: "dot.example.com", serverPort: 853),
            ],
            dnsHosts: [DNSHostMapping(domain: "home.lan", address: "192.168.1.10")],
            fakeIPEnabled: true,
            fakeIPExclusions: ["company.lan"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(decoded.dnsAddresses == ["1.1.1.1", "doh.example.com", "dot.example.com"])
    }

    @Test
    func decodeWithoutDNSResolversFallsBackToLegacyAddresses() throws {
        // Configurations persisted before resolvers existed carry only plain
        // addresses; they decode into UDP resolvers.
        let json = #"{"servers":[],"mtu":1500,"dnsAddresses":["9.9.9.9","149.112.112.112"]}"#
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: Data(json.utf8))
        #expect(decoded.dnsResolvers.count == 2)
        #expect(decoded.dnsResolvers[0].kind == .udp)
        #expect(decoded.dnsResolvers[0].server == "9.9.9.9")
        #expect(decoded.dnsResolvers[1].server == "149.112.112.112")
        #expect(decoded.dnsHosts.isEmpty)
        #expect(decoded.fakeIPEnabled == false)
    }

    @Test
    @MainActor
    func controllerUpdateDNSPersistsAndFillsDefault() throws {
        let suite = "test.waypo.controller.dns"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let resolvers = [
            DNSResolver(kind: .https, server: "doh.example.com", path: "/dns-query"),
        ]
        controller.updateDNS(resolvers: resolvers,
                             hosts: [DNSHostMapping(domain: "home.lan", address: "192.168.1.10")],
                             fakeIPEnabled: true, fakeIPExclusions: ["company.lan"])
        #expect(controller.configuration.dnsResolvers == resolvers)
        #expect(controller.configuration.fakeIPEnabled)

        // An empty resolver list is replaced with the fallback.
        controller.updateDNS(resolvers: [], hosts: [],
                             fakeIPEnabled: false, fakeIPExclusions: [])
        #expect(controller.configuration.dnsResolvers.count == 1)
        #expect(controller.configuration.dnsResolvers[0].server == "1.1.1.1")

        // The update persisted to the store.
        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.configuration.dnsResolvers[0].server == "1.1.1.1")
    }

    @Test
    func rulesRoundTrip() throws {
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            rules: [
                RoutingRule(domains: ["ads.example.com"], ports: [80, 443],
                            action: .reject),
                RoutingRule(ipCIDRs: ["10.0.0.0/8"], invert: true,
                            action: .route, outboundID: UUID()),
            ],
            ruleSets: [RemoteRuleSet(name: "Ads", url: "https://example.com/ads.json",
                                     updateInterval: 21600)]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(decoded.rules.count == 2)
        #expect(decoded.rules[0].action == .reject)
        #expect(decoded.rules[1].invert)
        #expect(decoded.ruleSets[0].name == "Ads")
    }

    @Test
    func decodeWithoutRulesKeepsEmptyLists() throws {
        // Configurations persisted before rules existed must still load.
        let json = #"{"servers":[],"mtu":1500,"dnsAddresses":["1.1.1.1"]}"#
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: Data(json.utf8))
        #expect(decoded.rules.isEmpty)
        #expect(decoded.ruleSets.isEmpty)
    }

    @Test
    @MainActor
    func controllerRulesAndOrderingPersist() throws {
        let suite = "test.waypo.controller.rules"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let first = RoutingRule(domainSuffixes: ["a.example"], action: .reject)
        let second = RoutingRule(domainKeywords: ["bank"], action: .direct)
        controller.updateRules([first, second])
        #expect(controller.configuration.rules.map(\.id) == [first.id, second.id])

        controller.moveRule(second, up: true)
        #expect(controller.configuration.rules.map(\.id) == [second.id, first.id])
        // Moving the top rule up is a no-op.
        controller.moveRule(second, up: true)
        #expect(controller.configuration.rules.map(\.id) == [second.id, first.id])

        let set = RemoteRuleSet(name: "Ads", url: "https://example.com/ads.json")
        controller.updateRuleSets([set])
        #expect(controller.configuration.ruleSets == [set])

        // Everything survived persistence.
        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.configuration.rules.map(\.id) == [second.id, first.id])
        #expect(reloaded.configuration.ruleSets == [set])
    }

    @Test
    func statusMirrorRoundTrip() throws {
        let suite = "test.waypo.store.status-mirror"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        #expect(store.loadStatusMirror() == nil)
        store.saveStatusMirror(NEVPNStatus.connected.rawValue)
        #expect(store.loadStatusMirror() == NEVPNStatus.connected.rawValue)
        store.saveStatusMirror(NEVPNStatus.disconnected.rawValue)
        #expect(store.loadStatusMirror() == NEVPNStatus.disconnected.rawValue)
    }

    @Test
    @MainActor
    func controllerRuleOutboundReferencesSurviveDeletion() throws {
        let suite = "test.waypo.controller.rule-refs"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let server = TunnelServer(name: "A", host: "198.51.100.1", port: 443)
        controller.addServer(server)
        let group = PolicyGroup(name: "Pick", kind: .select, memberIDs: [server.id])
        controller.addGroup(group)

        let toServer = RoutingRule(domains: ["a.example"], action: .route, outboundID: server.id)
        let toGroup = RoutingRule(domains: ["b.example"], action: .route, outboundID: group.id)
        let toNothing = RoutingRule(domains: ["c.example"], action: .route, outboundID: nil)
        controller.updateRules([toServer, toGroup, toNothing])

        // Deleting a referenced target falls back to the active selection
        // rather than leaving a dangling reference in the engine config.
        controller.deleteServer(server.id)
        #expect(controller.configuration.rules[0].outboundID == nil)
        #expect(controller.configuration.rules[1].outboundID == group.id)
        #expect(controller.configuration.rules[2].outboundID == nil)

        controller.deleteGroup(group.id)
        #expect(controller.configuration.rules.allSatisfy { $0.outboundID == nil })
    }

    @Test
    @MainActor
    func controllerGroupCRUDAndSelection() throws {
        let suite = "test.waypo.controller.groups"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let a = TunnelServer(name: "A", host: "198.51.100.1", port: 443)
        let b = TunnelServer(name: "B", host: "198.51.100.2", port: 443)
        controller.addServer(a)
        controller.addServer(b)

        let group = PolicyGroup(name: "Pick", kind: .select, memberIDs: [a.id, b.id])
        controller.addGroup(group)
        #expect(controller.configuration.groups.count == 1)

        let serverOrderBefore = controller.configuration.servers.map(\.id)
        // Selecting the second member moves it to the front (the persisted
        // preference and next-start default).
        controller.setGroupMember(group: group.id, member: b.id)
        #expect(controller.configuration.groups[0].memberIDs.first == b.id)
        // The top-level server order is untouched by group selection.
        #expect(controller.configuration.servers.map(\.id) == serverOrderBefore)

        controller.deleteServer(a.id)
        #expect(controller.configuration.groups[0].memberIDs == [b.id])

        controller.deleteGroup(group.id)
        #expect(controller.configuration.groups.isEmpty)
    }
}
