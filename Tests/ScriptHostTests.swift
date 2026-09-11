import Foundation
import Testing

/// Runs `body` against a store backed by a suite private to this test, then
/// removes the domain. Never touches `group.org.waypo`.
private func withStore(_ body: (ScriptStore) async throws -> Void) async rethrows {
    let name = "org.waypo.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: name) }
    try await body(ScriptStore(suiteName: name))
}

@Suite
struct ScriptHTTPClientTests {
    private static let client = ScriptHTTPClient()

    /// The transport is never reached for a refused URL, so nothing is sent.
    private func refusal(_ url: String) async -> String? {
        do {
            _ = try await Self.client.perform(
                ScriptHTTPRequest(method: .get, url: url, headers: [:], body: nil))
            return nil
        } catch let error as ScriptHTTPError {
            return error.message
        } catch {
            return "unexpected error type"
        }
    }

    @Test
    func onlyHTTPAndHTTPSAreAllowed() async {
        let refused = ["file:///etc/hosts", "ftp://example.test/file", "data:text/plain,hi",
                       "javascript:alert(1)", "example.test/path", "not a url"]
        for url in refused {
            let message = await refusal(url)
            #expect(message != nil, "expected \(url) to be refused")
            #expect(message?.contains("http") == true)
        }
    }
}

@Suite
struct AppScriptHostTests {
    private func makeHost(store: ScriptStore,
                          notifier: any ScriptNotifying = FakeScriptNotifier(),
                          switchServer: @escaping @MainActor @Sendable (UUID) async -> Bool)
    -> AppScriptHost {
        AppScriptHost(store: store, notifier: notifier, http: ScriptHTTPClient(),
                      switchServer: switchServer)
    }

    @Test
    func thePrivateDictionaryIsDelegatedToTheStore() async throws {
        try await withStore { store in
            let host = makeHost(store: store, switchServer: { _ in false })
            let id = UUID()
            #expect(host.readPersistent(id).isEmpty)
            try host.writePersistent(["k": "v"], for: id)
            #expect(host.readPersistent(id) == ["k": "v"])
        }
    }

    @Test
    func aRefusedWriteReachesTheCaller() async {
        await withStore { store in
            let host = makeHost(store: store, switchServer: { _ in false })
            var oversized: [String: String] = [:]
            for index in 0...ScriptLimits.persistentKeys {
                oversized["key\(index)"] = "v"
            }
            #expect(throws: ScriptStoreError.persistentStoreFull) {
                try host.writePersistent(oversized, for: UUID())
            }
        }
    }

    @Test
    func aNotificationReachesTheNotifier() async {
        await withStore { store in
            let notifier = FakeScriptNotifier()
            let host = makeHost(store: store, notifier: notifier, switchServer: { _ in false })
            host.postNotification(title: "Title", subtitle: "Sub", body: "Body")
            let delivered = await waitUntil { notifier.posted.count == 1 }
            #expect(delivered)
            #expect(notifier.posted.first?.title == "Title")
            #expect(notifier.posted.first?.body == "Body")
        }
    }

    @Test
    func aServerSwitchIsDelegatedToTheCaller() async {
        await withStore { store in
            let known = UUID()
            let host = makeHost(store: store) { requested in requested == known }
            let accepted = await host.selectServer(known)
            let refused = await host.selectServer(UUID())
            #expect(accepted)
            #expect(!refused)
        }
    }

    @Test
    func aRequestIsPassedToTheHTTPClient() async {
        await withStore { store in
            let host = makeHost(store: store, switchServer: { _ in false })
            await #expect(throws: ScriptHTTPError.self) {
                try await host.perform(ScriptHTTPRequest(method: .get, url: "ftp://example.test/",
                                                         headers: [:], body: nil))
            }
        }
    }
}
