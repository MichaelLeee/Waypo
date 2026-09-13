import Foundation

/// A named, independently persisted set of servers and tunnel settings.
struct TunnelProfile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var configuration: TunnelConfiguration
    /// Present when this profile came from a remote source that should be
    /// fetched again. Absent for a profile the user built or imported by hand.
    ///
    /// This lives on the profile and not in a sibling store because the store
    /// already persists the whole profile set and mirrors only the active
    /// profile's configuration to the extension — so a stale subscription can
    /// never outlive its profile or reach the tunnel.
    var subscription: Subscription?

    init(id: UUID = UUID(), name: String,
         configuration: TunnelConfiguration = .empty,
         subscription: Subscription? = nil) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.subscription = subscription
    }
}

/// How a profile keeps itself current, and what the provider last said about
/// the account.
struct Subscription: Codable, Hashable, Sendable {
    /// Daily. Providers change their server list on the order of days, and a
    /// shorter default would spend the user's quota on fetches.
    static let defaultInterval: TimeInterval = 86_400

    var url: String
    var interval: TimeInterval = Subscription.defaultInterval
    var lastUpdated: Date?
    /// Why the last attempt failed, kept so the failure is visible until the
    /// next one succeeds. A failed refresh never changes the configuration.
    var lastError: String?
    var userInfo: SubscriptionUserInfo?
}

/// Everything the store persists for multi-profile support.
struct ProfileSet: Codable, Hashable, Sendable {
    var profiles: [TunnelProfile]
    var activeProfileID: UUID

    var activeProfile: TunnelProfile? {
        profiles.first { $0.id == activeProfileID }
    }
}
