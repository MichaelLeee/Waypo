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

    @Test
    func finalPolicyDefaultsToTheActiveSelection() throws {
        let config = TunnelConfiguration(servers: [], mtu: 1500)
        #expect(config.finalPolicy.kind == .active)
        #expect(config.finalPolicy.outboundID == nil)
        #expect(config.finalPolicy.isDefault)
    }

    @Test
    func decodeWithoutFinalPolicyUsesTheActiveSelection() throws {
        // Configurations persisted before the catch-all existed must still
        // load, and must load meaning what they meant: the active selection.
        let json = #"{"servers":[],"mtu":1500,"dnsAddresses":["1.1.1.1"]}"#
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: Data(json.utf8))
        #expect(decoded.finalPolicy == .active)
    }

    @Test
    func aDefaultFinalPolicyIsNotEncoded() throws {
        // The field postdates the persisted format; a configuration that does
        // not use it has to encode to exactly the bytes it used to.
        let config = TunnelConfiguration(servers: [], mtu: 1500)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(config)) as? [String: Any]
        #expect(json?["finalPolicy"] == nil)
    }

    @Test
    func finalPolicyRoundTrips() throws {
        let target = UUID()
        let config = TunnelConfiguration(
            servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
            mtu: 1500,
            finalPolicy: FinalPolicy(kind: .outbound, outboundID: target)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(decoded.finalPolicy.kind == .outbound)
        #expect(decoded.finalPolicy.outboundID == target)
    }

    @Test
    func directAndRejectFinalPoliciesRoundTrip() throws {
        for kind in [FinalPolicy.Kind.direct, .reject] {
            let config = TunnelConfiguration(servers: [], mtu: 1500,
                                             finalPolicy: FinalPolicy(kind: kind, outboundID: nil))
            let decoded = try JSONDecoder().decode(
                TunnelConfiguration.self, from: try JSONEncoder().encode(config))
            #expect(decoded.finalPolicy.kind == kind)
        }
    }

    @Test
    func subscriptionSurvivesAProfileRoundTrip() throws {
        let suite = "test.waypo.store.subscription"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let info = SubscriptionUserInfo(
            uploadBytes: 1_000,
            downloadBytes: 2_000_000,
            totalBytes: 10_000_000,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let subscription = Subscription(url: "https://example.com/sub",
                                        interval: 21_600,
                                        lastUpdated: Date(timeIntervalSince1970: 1_800_000_000),
                                        lastError: nil,
                                        userInfo: info)
        let profile = TunnelProfile(name: "Sub", configuration: .empty, subscription: subscription)

        let store = TunnelStore(suiteName: suite)
        try store.saveProfileSet(ProfileSet(profiles: [profile], activeProfileID: profile.id))
        let loaded = store.loadProfileSet().profiles.first
        #expect(loaded?.subscription == subscription)
        #expect(loaded?.subscription?.userInfo?.totalBytes == 10_000_000)

        // The profile carries it through a plain encode/decode as well.
        let decoded = try JSONDecoder().decode(
            TunnelProfile.self, from: try JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }

    @Test
    func decodeWithoutSubscriptionLeavesItNil() throws {
        // Profiles persisted before subscriptions existed have no such key.
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"Old","configuration":{"servers":[],"mtu":1500,"dnsAddresses":["1.1.1.1"]}}"#
        let profile = try JSONDecoder().decode(TunnelProfile.self, from: Data(json.utf8))
        #expect(profile.subscription == nil)
    }

    @Test
    func aStoredSubscriptionNeverReachesTheConfigurationMirror() throws {
        // The extension reads the mirrored configuration, so anything the
        // provider can see must be in the configuration and nothing else.
        let suite = "test.waypo.store.subscription-mirror"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let profile = TunnelProfile(
            name: "Sub",
            configuration: TunnelConfiguration(
                servers: [TunnelServer(name: "A", host: "198.51.100.1", port: 443)],
                mtu: 1500),
            subscription: Subscription(url: "https://example.com/sub")
        )
        try store.saveProfileSet(ProfileSet(profiles: [profile], activeProfileID: profile.id))

        let mirrored = String(decoding: try JSONEncoder().encode(store.loadConfiguration()),
                              as: UTF8.self)
        #expect(!mirrored.contains("subscription"))
        #expect(!mirrored.contains("example.com"))
    }
}

extension TunnelConfigurationTests {
    /// A document with a name, one server, a group over it, and a catch-all.
    private func sampleDocument(name: String = "Sample", host: String) -> String {
        """
        name: \(name)
        proxies:
          - name: \(name) Node
            type: trojan
            server: \(host)
            port: 443
            password: pw
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - \(name) Node
        rules:
          - DOMAIN-SUFFIX,example.com,Pick
          - MATCH,DIRECT
        """
    }

    @Test
    @MainActor
    func importConfigurationCreatesAndSwitchesToANewProfile() {
        let suite = "test.waypo.controller.import-config"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()
        let originalID = controller.activeProfileID

        let outcome = controller.importText(fromText: sampleDocument(host: "203.0.113.20"))
        guard case .configuration(let report) = outcome else {
            Issue.record("expected a configuration outcome, got \(outcome)")
            return
        }
        #expect(report.serversImported == 1)
        #expect(report.groupsImported == 1)
        // The catch-all becomes the final policy, so it is not counted here.
        #expect(report.rulesImported == 1)
        #expect(controller.profiles.count == 2)
        #expect(controller.activeProfile?.name == "Sample")
        #expect(controller.activeProfileID != originalID)
        #expect(controller.configuration.servers.map(\.name) == ["Sample Node"])
        #expect(controller.configuration.finalPolicy.kind == .direct)

        // The new profile is what a later launch loads, and the profile that
        // was active before is untouched.
        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.activeProfile?.name == "Sample")
        #expect(reloaded.configuration.servers.map(\.name) == ["Sample Node"])
        let original = reloaded.profiles.first { $0.id == originalID }
        #expect(original?.configuration.servers.isEmpty == true)
    }

    @Test
    @MainActor
    func importTextFallsBackToAppendingEntries() {
        let suite = "test.waypo.controller.import-links"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        #expect(controller.importText(fromText: "trojan://pw@192.0.2.3:443#One")
            == .servers(added: 1))
        #expect(controller.profiles.count == 1)
        #expect(controller.configuration.servers.map(\.name) == ["One"])
        // A repeat of an entry already in the profile adds nothing.
        #expect(controller.importText(fromText: "trojan://pw@192.0.2.3:443#One")
            == .servers(added: 0))
        #expect(controller.configuration.servers.count == 1)
    }

    @Test
    @MainActor
    func importSkipsRepeatsWithinOneBatch() {
        let suite = "test.waypo.controller.import-batch"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let text = """
        trojan://pw@192.0.2.3:443#One
        trojan://pw@192.0.2.3:443#One again
        """
        #expect(controller.importServers(fromText: text) == 1)
        #expect(controller.configuration.servers.map(\.name) == ["One"])
    }

    @Test
    @MainActor
    func aDocumentWithoutServersAddsNoProfile() {
        let suite = "test.waypo.controller.import-empty"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let text = "proxy-groups:\n  - name: Pick\n    type: select\n"
        let outcome = controller.importText(fromText: text)
        guard case .configuration(let report) = outcome else {
            Issue.record("expected a configuration outcome, got \(outcome)")
            return
        }
        #expect(controller.profiles.count == 1)
        #expect(report.droppedCount >= 1)
        #expect(report.notices.contains { $0.detail.contains("no profile was created") })
    }

    @Test
    @MainActor
    func importingTheSameDocumentTwiceKeepsBothProfilesApart() {
        let suite = "test.waypo.controller.import-duplicate"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        controller.importText(fromText: sampleDocument(host: "203.0.113.20"))
        controller.importText(fromText: sampleDocument(host: "203.0.113.21"))

        #expect(controller.profiles.count == 3)
        let names = controller.profiles.suffix(2).map(\.name)
        #expect(names == ["Sample", "Sample 2"])
    }

    @Test
    @MainActor
    func deleteGroupRemovesNestedMembership() {
        let suite = "test.waypo.controller.delete-group"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let node = TunnelServer(name: "Node", host: "198.51.100.9", port: 443)
        controller.addServer(node)
        let inner = PolicyGroup(name: "Inner", kind: .select, memberIDs: [node.id])
        controller.addGroup(inner)
        let outer = PolicyGroup(name: "Outer", kind: .select, memberIDs: [inner.id, node.id])
        controller.addGroup(outer)
        #expect(controller.configuration.groups[1].memberIDs.count == 2)

        controller.deleteGroup(inner.id)
        #expect(controller.configuration.groups.count == 1)
        #expect(controller.configuration.groups[0].memberIDs == [node.id])
    }

    @Test
    @MainActor
    func importingASubscriptionCreatesAProfileThatKeepsItselfCurrent() async throws {
        let suite = "test.waypo.controller.subscription-import"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        let info = try #require(SubscriptionUserInfo.parse("upload=1024; download=2048; total=4096"))
        let outcome = await controller.importSubscription(
            urlString: url, interval: 21_600,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(host: "203.0.113.30"),
                                                     userInfo: info, for: url))
        guard case .configuration(let report) = outcome else {
            Issue.record("expected a configuration outcome, got \(outcome)")
            return
        }
        #expect(report.serversImported == 1)
        #expect(controller.profiles.count == 2)

        let profile = try #require(controller.activeProfile)
        #expect(profile.name == "Sample")
        #expect(profile.subscription?.url == url)
        #expect(profile.subscription?.interval == 21_600)
        #expect(profile.subscription?.lastUpdated != nil)
        #expect(profile.subscription?.lastError == nil)
        #expect(profile.subscription?.userInfo?.totalBytes == 4096)
        #expect(controller.configuration.servers.map(\.name) == ["Sample Node"])

        // The source survives a relaunch along with the servers.
        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.activeProfile?.subscription?.url == url)
        #expect(reloaded.activeProfile?.subscription?.interval == 21_600)
    }

    @Test
    @MainActor
    func refreshDueSubscriptionsHonoursTheInterval() async {
        let suite = "test.waypo.controller.subscription-due"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        _ = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(name: "Alpha",
                                                                    host: "203.0.113.31"),
                                                     for: url))

        let fetcher = FakeSubscriptionFetcher.alwaysServing(
            sampleDocument(name: "Beta", host: "203.0.113.32"))
        // Still inside the interval, so nothing is read.
        await controller.refreshDueSubscriptions(fetcher: fetcher)
        #expect(fetcher.requested.isEmpty)
        #expect(controller.configuration.servers.map(\.name) == ["Alpha Node"])

        await controller.refreshDueSubscriptions(now: Date().addingTimeInterval(2 * 86_400),
                                                 fetcher: fetcher)
        #expect(fetcher.requested == [url])
        #expect(controller.configuration.servers.map(\.name) == ["Beta Node"])
    }

    @Test
    @MainActor
    func aRefreshReplacesTheServersAndKeepsTheProfileName() async throws {
        let suite = "test.waypo.controller.subscription-refresh"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        _ = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(name: "Alpha",
                                                                    host: "203.0.113.31"),
                                                     for: url))
        #expect(controller.configuration.servers.map(\.name) == ["Alpha Node"])

        let id = controller.activeProfileID
        let info = try #require(SubscriptionUserInfo.parse("upload=1024; total=4096"))
        await controller.refreshSubscription(
            for: id, force: true,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(name: "Beta",
                                                                    host: "203.0.113.32"),
                                                     userInfo: info, for: url))
        // The document changed; the profile it belongs to did not.
        #expect(controller.configuration.servers.map(\.name) == ["Beta Node"])
        #expect(controller.activeProfile?.name == "Alpha")
        #expect(controller.activeProfile?.subscription?.userInfo?.totalBytes == 4096)
        #expect(controller.activeProfile?.subscription?.lastError == nil)

        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.configuration.servers.map(\.name) == ["Beta Node"])
    }

    @Test
    @MainActor
    func aFailedRefreshKeepsThePreviousServersAndStaysDue() async throws {
        let suite = "test.waypo.controller.subscription-failure"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        let info = try #require(SubscriptionUserInfo.parse("upload=7; total=4096"))
        _ = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(name: "Alpha",
                                                                    host: "203.0.113.31"),
                                                     userInfo: info, for: url))
        let id = controller.activeProfileID
        let updatedAt = try #require(controller.activeProfile?.subscription?.lastUpdated)

        await controller.refreshSubscription(
            for: id, force: true, now: Date().addingTimeInterval(3_600),
            fetcher: FakeSubscriptionFetcher.failing(.httpStatus(503), for: url))
        #expect(controller.configuration.servers.map(\.name) == ["Alpha Node"])
        #expect(controller.activeProfile?.subscription?.lastError?.contains("503") == true)
        // The clock does not advance on a failure, so the profile stays due and
        // is retried at the next opportunity.
        #expect(controller.activeProfile?.subscription?.lastUpdated == updatedAt)
        // A source that stops answering does not erase what it last reported.
        #expect(controller.activeProfile?.subscription?.userInfo?.totalBytes == 4096)

        // A later good answer replaces the servers and clears the message.
        await controller.refreshSubscription(
            for: id, force: true,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(name: "Beta",
                                                                    host: "203.0.113.32"),
                                                     for: url))
        #expect(controller.configuration.servers.map(\.name) == ["Beta Node"])
        #expect(controller.activeProfile?.subscription?.lastError == nil)
        #expect(controller.activeProfile?.subscription?.userInfo?.totalBytes == 4096)
    }

    @Test
    @MainActor
    func detachingASubscriptionKeepsTheServers() async throws {
        let suite = "test.waypo.controller.subscription-detach"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        _ = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving(sampleDocument(host: "203.0.113.31"),
                                                     for: url))

        controller.detachSubscription()
        #expect(controller.activeProfile?.subscription == nil)
        #expect(controller.configuration.servers.map(\.name) == ["Sample Node"])

        let reloaded = TunnelController(store: store)
        reloaded.reloadProfiles()
        #expect(reloaded.activeProfile?.subscription == nil)
        #expect(reloaded.configuration.servers.count == 1)
    }

    @Test
    @MainActor
    func aSourceThatServesOnlyEntriesBecomesAProfileNamedAfterIt() async throws {
        let suite = "test.waypo.controller.subscription-entries"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        let outcome = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving("trojan://pw@192.0.2.40:443#One",
                                                     suggestedName: "Provider", for: url))
        guard case .configuration(let report) = outcome else {
            Issue.record("expected a configuration outcome, got \(outcome)")
            return
        }
        #expect(report.serversImported == 1)
        #expect(controller.activeProfile?.name == "Provider")
        #expect(controller.profiles.count == 2)
    }

    @Test
    @MainActor
    func aDocumentWithoutANameFallsBackToTheSourceHost() async {
        let suite = "test.waypo.controller.subscription-host-name"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "https://provider.example.com/sub"
        let document = """
        proxies:
          - name: Node
            type: trojan
            server: 203.0.113.50
            port: 443
            password: pw
        """
        _ = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.serving(document, for: url))
        #expect(controller.activeProfile?.name == "provider.example.com")
    }

    @Test
    @MainActor
    func aSourceThatCannotBeReachedAddsNoProfile() async {
        let suite = "test.waypo.controller.subscription-unreachable"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = TunnelStore(suiteName: suite)
        let controller = TunnelController(store: store)
        controller.reloadProfiles()

        let url = "ftp://provider.example.com/sub"
        let outcome = await controller.importSubscription(
            urlString: url, interval: 86_400,
            fetcher: FakeSubscriptionFetcher.failing(.unsupportedScheme("ftp"), for: url))
        guard case .failure(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("http and https"))
        #expect(controller.profiles.count == 1)
        #expect(controller.configuration.servers.isEmpty)
    }
}
