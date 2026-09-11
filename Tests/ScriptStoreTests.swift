import Foundation
import Testing

/// The key names the store writes under. Spelled out here on purpose: the
/// tests that inspect raw bytes have to reach past the load-path sanitiser,
/// and `#require` turns a rename into a loud failure rather than a silent pass.
private let definitionsKey = "scriptDefinitions"
private let historyKey = "scriptRunHistory"

private func script(_ name: String, origin: ScriptOrigin = .user,
                    enabled: Bool = true) -> Script {
    Script(name: name, kind: .manual, source: "console.log(1)",
           isEnabled: enabled, origin: origin,
           createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func record(_ index: Int) -> ScriptRunRecord {
    ScriptRunRecord(scriptID: UUID(), scriptName: "S\(index)", trigger: .manual,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    duration: 0.1, outcome: .success)
}

/// Runs `body` against a store backed by a suite private to this test, then
/// removes the domain. Never touches `group.org.waypo`.
private func withStore(_ body: (ScriptStore, String) throws -> Void) rethrows {
    let name = "org.waypo.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: name) }
    try body(ScriptStore(suiteName: name), name)
}

@Suite
struct ScriptStoreTests {
    // MARK: - Definitions

    @Test
    func anEmptySuiteLoadsNothing() {
        withStore { store, _ in
            #expect(store.loadScripts().isEmpty)
        }
    }

    @Test
    func scriptsRoundTripInOrder() throws {
        try withStore { store, _ in
            let scripts = [script("A"), script("B"), script("C")]
            try store.saveScripts(scripts)
            let loaded = store.loadScripts()
            #expect(loaded.map(\.id) == scripts.map(\.id))
            #expect(loaded.map(\.name) == ["A", "B", "C"])
        }
    }

    @Test
    func unreadableDataLoadsAsNothing() throws {
        try withStore { store, name in
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(Data("not json at all".utf8), forKey: definitionsKey)
            #expect(store.loadScripts().isEmpty)

            defaults.set(Data(#"{"name":"not an array"}"#.utf8), forKey: definitionsKey)
            #expect(store.loadScripts().isEmpty)
        }
    }

    // MARK: - Import sanitiser

    @Test
    func savingForcesAnImportedScriptDisabled() throws {
        try withStore { store, name in
            try store.saveScripts([script("Fetched", origin: .imported, enabled: true)])

            // Read the bytes directly: going through `saveScripts` and then
            // `loadScripts` would pass even if only the load path sanitised.
            let stored = try #require(UserDefaults(suiteName: name)?
                .data(forKey: definitionsKey))
            let decoded = try JSONDecoder().decode([Script].self, from: stored)
            #expect(decoded.count == 1)
            #expect(decoded[0].isEnabled == false)
            #expect(decoded[0].origin == .imported)
        }
    }

    @Test
    func loadingForcesAnImportedScriptDisabled() throws {
        try withStore { store, name in
            let raw = [script("Fetched", origin: .imported, enabled: true),
                       script("Mine", origin: .user, enabled: true)]
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(try JSONEncoder().encode(raw), forKey: definitionsKey)

            let loaded = store.loadScripts()
            #expect(loaded.count == 2)
            #expect(loaded[0].isEnabled == false)
            #expect(loaded[1].isEnabled)
        }
    }

    @Test
    func anAlreadyDisabledImportedScriptIsLeftAlone() throws {
        try withStore { store, name in
            let raw = [script("Fetched", origin: .imported, enabled: false)]
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(try JSONEncoder().encode(raw), forKey: definitionsKey)

            let loaded = store.loadScripts()
            #expect(loaded.count == 1)
            #expect(loaded[0].isEnabled == false)
        }
    }

    @Test
    func aUserScriptKeepsItsEnabledState() throws {
        try withStore { store, name in
            try store.saveScripts([script("Mine")])

            let stored = try #require(UserDefaults(suiteName: name)?
                .data(forKey: definitionsKey))
            let decoded = try JSONDecoder().decode([Script].self, from: stored)
            #expect(decoded[0].isEnabled)
            #expect(store.loadScripts()[0].isEnabled)
        }
    }

    // MARK: - History

    @Test
    func historyRoundTripsNewestFirst() throws {
        try withStore { store, _ in
            let records = (0..<5).reversed().map(record)
            try store.saveHistory(Array(records))
            let loaded = store.loadHistory()
            #expect(loaded.map(\.scriptName) == ["S4", "S3", "S2", "S1", "S0"])
        }
    }

    @Test
    func savingTrimsHistoryToTheCap() throws {
        try withStore { store, _ in
            try store.saveHistory((0..<150).reversed().map(record))
            let loaded = store.loadHistory()
            #expect(loaded.count == ScriptLimits.history)
            #expect(loaded.first?.scriptName == "S149")
            #expect(loaded.last?.scriptName == "S50")
        }
    }

    @Test
    func loadingTrimsAnOverlongStoredHistory() throws {
        try withStore { store, name in
            let raw = (0..<150).reversed().map(record)
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(try JSONEncoder().encode(Array(raw)), forKey: historyKey)

            let loaded = store.loadHistory()
            #expect(loaded.count == ScriptLimits.history)
            #expect(loaded.first?.scriptName == "S149")
        }
    }

    @Test
    func unreadableHistoryLoadsAsNothing() throws {
        try withStore { store, name in
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(Data([0x00, 0x01, 0x02]), forKey: historyKey)
            #expect(store.loadHistory().isEmpty)
        }
    }

    // MARK: - Per-script store

    @Test
    func eachScriptGetsItsOwnStore() throws {
        try withStore { store, _ in
            let a = UUID()
            let b = UUID()
            try store.savePersistentStore(["count": "3"], for: a)
            #expect(store.persistentStore(for: a) == ["count": "3"])
            #expect(store.persistentStore(for: b).isEmpty)
            #expect(store.persistentStore(for: UUID()).isEmpty)
        }
    }

    @Test
    func deletingOneStoreLeavesTheOthers() throws {
        try withStore { store, _ in
            let a = UUID()
            let b = UUID()
            try store.savePersistentStore(["k": "a"], for: a)
            try store.savePersistentStore(["k": "b"], for: b)

            store.deletePersistentStore(for: a)
            #expect(store.persistentStore(for: a).isEmpty)
            #expect(store.persistentStore(for: b) == ["k": "b"])
        }
    }

    @Test
    func overwritingAStoreReplacesItWholesale() throws {
        try withStore { store, _ in
            let id = UUID()
            try store.savePersistentStore(["a": "1", "b": "2"], for: id)
            try store.savePersistentStore(["a": "9"], for: id)
            #expect(store.persistentStore(for: id) == ["a": "9"])
        }
    }

    @Test
    func anEmptyStoreIsWritable() throws {
        try withStore { store, _ in
            let id = UUID()
            try store.savePersistentStore([:], for: id)
            #expect(store.persistentStore(for: id).isEmpty)
        }
    }

    @Test
    func tooManyKeysAreRefused() throws {
        try withStore { store, _ in
            let id = UUID()
            let allowed = Dictionary(uniqueKeysWithValues:
                (0..<ScriptLimits.persistentKeys).map { ("k\($0)", "v") })
            try store.savePersistentStore(allowed, for: id)
            #expect(store.persistentStore(for: id).count == ScriptLimits.persistentKeys)

            var tooMany = allowed
            tooMany["one-more"] = "v"
            #expect(throws: ScriptStoreError.persistentStoreFull) {
                try store.savePersistentStore(tooMany, for: id)
            }
            // The refused write left the previous contents in place.
            #expect(store.persistentStore(for: id).count == ScriptLimits.persistentKeys)
        }
    }

    @Test
    func anOversizedStoreIsRefused() throws {
        try withStore { store, _ in
            let id = UUID()
            let oversized = ["blob": String(repeating: "x", count: 300_000)]
            #expect(throws: ScriptStoreError.persistentStoreFull) {
                try store.savePersistentStore(oversized, for: id)
            }
            #expect(store.persistentStore(for: id).isEmpty)
        }
    }

    @Test
    func aStoreJustUnderTheByteCapIsAccepted() throws {
        try withStore { store, _ in
            let id = UUID()
            // Encoded as `{"blob":"…"}` — 12 bytes of JSON syntax around it.
            let value = String(repeating: "x", count: ScriptLimits.persistentBytes - 12)
            try store.savePersistentStore(["blob": value], for: id)
            #expect(store.persistentStore(for: id)["blob"] == value)
        }
    }
}

@Suite
struct ScriptLimitsTests {
    @Test
    func textWithinBudgetIsUntouched() {
        #expect(ScriptLimits.truncate("abc", toUTF8Bytes: 10) == "abc")
        #expect(ScriptLimits.truncate("", toUTF8Bytes: 10) == "")
        #expect(ScriptLimits.truncate("abcdefghij", toUTF8Bytes: 10) == "abcdefghij")
    }

    @Test
    func overlongTextIsCutAndMarked() {
        let cut = ScriptLimits.truncate("abcdefghij", toUTF8Bytes: 5)
        #expect(cut == "ab…")
        #expect(cut.utf8.count == 5)
    }

    @Test
    func aBudgetTooSmallForTheEllipsisYieldsNothing() {
        #expect(ScriptLimits.truncate("abcdefghij", toUTF8Bytes: 2) == "")
        #expect(ScriptLimits.truncate("abcdefghij", toUTF8Bytes: 0) == "")
    }

    @Test
    func multiByteCharactersAreNeverSplit() {
        let accented = String(repeating: "é", count: 100)
        let cut = ScriptLimits.truncate(accented, toUTF8Bytes: 7)
        #expect(cut.utf8.count <= 7)
        #expect(cut.hasSuffix("…"))
        #expect(String(cut.dropLast()) == "éé")

        let emoji = String(repeating: "🌐", count: 50)
        let emojiCut = ScriptLimits.truncate(emoji, toUTF8Bytes: 10)
        #expect(emojiCut.utf8.count <= 10)
        #expect(emojiCut == "🌐…")
    }

    @Test
    func logTruncationKeepsWholeLines() {
        let lines = (0..<100).map { String(repeating: "\($0 % 10)", count: 100) }
        let kept = ScriptLimits.truncateLog(lines)

        // 101 bytes per line against a 2048-byte budget.
        #expect(kept.count == 20)
        #expect(kept == Array(lines.prefix(20)))
        #expect(kept.reduce(0) { $0 + $1.utf8.count + 1 } <= ScriptLimits.logBytes)
    }

    @Test
    func aLogThatFitsIsUnchanged() {
        let lines = ["one", "two", "three"]
        #expect(ScriptLimits.truncateLog(lines) == lines)
        #expect(ScriptLimits.truncateLog([]).isEmpty)
    }
}
