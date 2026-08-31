import Foundation

/// Persists tunnel configuration in the App Group container so both the app
/// and the packet tunnel extension read the same source of truth.
struct TunnelStore {
    static let appGroupID = "group.org.waypo"

    private let suiteName: String

    init(suiteName: String = TunnelStore.appGroupID) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    func loadConfiguration() -> TunnelConfiguration {
        guard let data = defaults?.data(forKey: Keys.configuration),
              let config = try? JSONDecoder().decode(TunnelConfiguration.self, from: data)
        else {
            return .default
        }
        return config
    }

    func saveConfiguration(_ config: TunnelConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        defaults?.set(data, forKey: Keys.configuration)
        try writeMirror(data)
    }

    /// Also mirrors the configuration to a plain JSON file under the user's
    /// Application Support directory so the harness CLI (running outside the
    /// App Group sandbox) can read the same configuration.
    private func writeMirror(_ data: Data) throws {
        let fileManager = FileManager.default
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Waypo", isDirectory: true) as URL?
        else { return }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: directory.appendingPathComponent("tunnel-configuration.json"), options: .atomic)
    }

    private enum Keys {
        static let configuration = "tunnelConfiguration"
    }
}
