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

    // MARK: - Active configuration (what the provider extension reads)

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

    // MARK: - Profiles

    /// Loads the profile set, migrating a legacy single configuration into a
    /// "Default" profile on first read so nothing the user configured is lost.
    func loadProfileSet() -> ProfileSet {
        if let data = defaults?.data(forKey: Keys.profiles),
           let set = try? JSONDecoder().decode(ProfileSet.self, from: data),
           set.activeProfile != nil, !set.profiles.isEmpty {
            return set
        }
        let migrated = TunnelProfile(name: "Default", configuration: loadConfiguration())
        return ProfileSet(profiles: [migrated], activeProfileID: migrated.id)
    }

    func saveProfileSet(_ set: ProfileSet) throws {
        guard set.activeProfile != nil else {
            throw NSError(domain: "Waypo", code: 2, userInfo: [NSLocalizedDescriptionKey: "profile set has no active profile"])
        }
        let data = try JSONEncoder().encode(set)
        defaults?.set(data, forKey: Keys.profiles)
        // The provider extension still reads the single-configuration key;
        // mirror the active profile into it so the tunnel path is unchanged.
        try saveConfiguration(set.activeProfile!.configuration)
    }

    /// Also mirrors the configuration to a plain JSON file under the user's
    /// Application Support directory so the harness CLI (running outside the
    /// App Group sandbox) can read the same configuration. Only the real App
    /// Group suite mirrors; test suites must not touch the user's file.
    private func writeMirror(_ data: Data) throws {
        guard suiteName == TunnelStore.appGroupID else { return }
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
        static let profiles = "tunnelProfiles"
    }
}
