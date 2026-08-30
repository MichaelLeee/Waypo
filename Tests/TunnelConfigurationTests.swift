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
}
