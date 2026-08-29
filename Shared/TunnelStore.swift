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
    }

    private enum Keys {
        static let configuration = "tunnelConfiguration"
    }
}
