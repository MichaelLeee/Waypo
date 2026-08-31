import Foundation
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
}
