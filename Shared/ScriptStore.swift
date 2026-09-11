import Foundation

/// Persists script definitions, run history, and each script's private
/// key-value store in the App Group container.
///
/// Unlike `TunnelStore` there is deliberately no plain-file mirror: script
/// source and its stored values must not be visible to the harness or the
/// packet tunnel provider.
struct ScriptStore {
    private let suiteName: String

    init(suiteName: String = TunnelStore.appGroupID) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // MARK: - Definitions

    /// Empty when nothing is stored or the stored data is unreadable.
    func loadScripts() -> [Script] {
        guard let data = defaults?.data(forKey: Keys.definitions),
              let scripts = try? JSONDecoder().decode([Script].self, from: data)
        else { return [] }
        return sanitized(scripts)
    }

    func saveScripts(_ scripts: [Script]) throws {
        let data = try JSONEncoder().encode(sanitized(scripts))
        defaults?.set(data, forKey: Keys.definitions)
    }

    // MARK: - Run history

    /// Newest first, capped. Callers prepend new records.
    func loadHistory() -> [ScriptRunRecord] {
        guard let data = defaults?.data(forKey: Keys.history),
              let records = try? JSONDecoder().decode([ScriptRunRecord].self, from: data)
        else { return [] }
        return Array(records.prefix(ScriptLimits.history))
    }

    func saveHistory(_ records: [ScriptRunRecord]) throws {
        let data = try JSONEncoder().encode(Array(records.prefix(ScriptLimits.history)))
        defaults?.set(data, forKey: Keys.history)
    }

    // MARK: - Per-script store

    func persistentStore(for scriptID: UUID) -> [String: String] {
        guard let data = defaults?.data(forKey: Keys.persistentStore(scriptID)),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    func savePersistentStore(_ values: [String: String], for scriptID: UUID) throws {
        guard values.count <= ScriptLimits.persistentKeys else {
            throw ScriptStoreError.persistentStoreFull
        }
        let data = try JSONEncoder().encode(values)
        guard data.count <= ScriptLimits.persistentBytes else {
            throw ScriptStoreError.persistentStoreFull
        }
        defaults?.set(data, forKey: Keys.persistentStore(scriptID))
    }

    func deletePersistentStore(for scriptID: UUID) {
        defaults?.removeObject(forKey: Keys.persistentStore(scriptID))
    }

    // MARK: - Import sanitiser

    /// The security guarantee: an imported script never auto-runs. Applied on
    /// the way in and on the way out, so neither a stored value nor a caller
    /// can re-enable one.
    private func sanitized(_ scripts: [Script]) -> [Script] {
        scripts.map { script in
            guard script.origin == .imported, script.isEnabled else { return script }
            var disabled = script
            disabled.isEnabled = false
            return disabled
        }
    }

    private enum Keys {
        static let definitions = "scriptDefinitions"
        static let history = "scriptRunHistory"
        static func persistentStore(_ id: UUID) -> String { "scriptStore.\(id.uuidString)" }
    }
}

enum ScriptStoreError: Error, Equatable {
    case persistentStoreFull
}

/// Ceilings on everything a script can accumulate.
enum ScriptLimits {
    static let history = 100
    static let outputBytes = 8 * 1024
    static let logBytes = 2 * 1024
    static let persistentKeys = 256
    static let persistentBytes = 256 * 1024

    /// Truncates to at most `limit` UTF-8 bytes without splitting a
    /// character, marking the cut with an ellipsis.
    static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        guard limit >= 3 else { return "" }
        let budget = limit - 3
        var kept = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            kept.append(character)
            used += size
        }
        return kept + "…"
    }

    /// Keeps the leading lines that fit the total byte budget. A line that
    /// does not fit is dropped whole rather than cut mid-line.
    static func truncateLog(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in lines {
            let size = line.utf8.count + 1
            if used + size > logBytes { break }
            kept.append(line)
            used += size
        }
        return kept
    }
}
