import Foundation

/// A named, independently persisted set of servers and tunnel settings.
struct TunnelProfile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var configuration: TunnelConfiguration

    init(id: UUID = UUID(), name: String, configuration: TunnelConfiguration = .empty) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}

/// Everything the store persists for multi-profile support.
struct ProfileSet: Codable, Hashable, Sendable {
    var profiles: [TunnelProfile]
    var activeProfileID: UUID

    var activeProfile: TunnelProfile? {
        profiles.first { $0.id == activeProfileID }
    }
}
