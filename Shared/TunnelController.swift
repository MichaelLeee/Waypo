import Foundation
import NetworkExtension
import Observation
import WidgetKit

/// App-side control of the tunnel profile and connection.
@MainActor
@Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid {
        didSet {
            // Set on the transition; the connection object exposes no start
            // date, so reconnects inside a running session restart the clock.
            if status == .connected, connectedSince == nil {
                connectedSince = Date()
            } else if status != .connected {
                connectedSince = nil
            }
            // Mirror the status for the widget, which cannot read the
            // profile manager itself.
            store.saveStatusMirror(status.rawValue)
            WidgetCenter.shared.reloadAllTimelines()
            updateStatsPolling()
            onStatusTransition?(oldValue, status)
        }
    }

    /// Called at the end of every status change with the status it came from
    /// and the status it went to. Assigned by the scripting service so events
    /// follow real transitions; anything else leaves it nil.
    var onStatusTransition: (@MainActor (NEVPNStatus, NEVPNStatus) -> Void)?
    private(set) var connectedSince: Date?
    private(set) var isOnDemandEnabled = false
    private(set) var traffic: CoreStats?
    private(set) var lastError: String?
    private(set) var latencies: [TunnelServer.ID: Double] = [:]
    private(set) var groupStates: [PolicyGroupState] = []
    private(set) var connections: [EngineConnection] = []
    /// The extension's own memory reading. Only the extension process can see
    /// the figure it is actually limited by, so this is the number that
    /// decides whether request interception fits there.
    private(set) var memory: MemoryFootprint?
    private(set) var isTestingLatency = false
    /// True while a source is being read, so a foreground refresh and a manual
    /// one cannot both be in flight against the same profile.
    private(set) var isRefreshingSubscription = false
    var configuration: TunnelConfiguration = .default
    private(set) var profiles: [TunnelProfile] = []
    private(set) var activeProfileID = UUID()

    var activeProfile: TunnelProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    private let store: TunnelStore
    private var manager: NETunnelProviderManager?
    private var observing = false
    private var statsTask: Task<Void, Never>?

    var isActive: Bool { status == .connected || status == .connecting }

    func isActiveServer(_ id: TunnelServer.ID) -> Bool {
        configuration.servers.first?.id == id
    }

    init(store: TunnelStore = TunnelStore()) {
        self.store = store
    }

    /// Profile state only; split out so tests can exercise it without
    /// touching the profile manager.
    func reloadProfiles() {
        let set = store.loadProfileSet()
        profiles = set.profiles
        activeProfileID = set.activeProfileID
        configuration = set.activeProfile?.configuration ?? .default
    }

    func refresh() async {
        reloadProfiles()
        // Ensure the harness CLI's config mirror exists even if the user
        // never edited anything since the profile feature landed.
        if activeProfile != nil {
            persist()
        }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first { $0.localizedDescription == Self.profileTitle }
            self.manager = manager
            status = manager?.connection.status ?? .invalid
            isOnDemandEnabled = manager?.onDemandRules?.isEmpty == false
            observeStatus(of: manager)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggle() async {
        do {
            let manager = try await loadOrCreateManager()
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                manager.connection.stopVPNTunnel()
            case .disconnected, .invalid:
                try manager.connection.startVPNTunnel()
            default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Connect On Demand keeps the tunnel up across app restarts, network
    /// switches, and reboots: a single always-connect on-demand rule makes
    /// the system bring the tunnel back whenever it is down.
    func setOnDemand(_ enabled: Bool) async {
        isOnDemandEnabled = enabled
        do {
            let manager = try await loadOrCreateManager()
            // On-demand state lives on the manager, not the protocol.
            manager.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : []
            manager.isOnDemandEnabled = enabled
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            isOnDemandEnabled = enabled
            status = manager.connection.status
            lastError = nil
        } catch {
            isOnDemandEnabled = !enabled
            lastError = error.localizedDescription
        }
    }

    var uptimeLabel: String? {
        guard let connectedSince else { return nil }
        return Duration.seconds(Date().timeIntervalSince(connectedSince))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    // MARK: - Server management

    func addServer(_ server: TunnelServer) {
        configuration.servers.append(server)
        persist()
    }

    func updateServer(_ server: TunnelServer) {
        guard let index = configuration.servers.firstIndex(where: { $0.id == server.id }) else { return }
        configuration.servers[index] = server
        persist()
    }

    func deleteServer(_ id: TunnelServer.ID) {
        configuration.servers.removeAll { $0.id == id }
        for index in configuration.groups.indices {
            configuration.groups[index].memberIDs.removeAll { $0 == id }
        }
        // Rules pointing at the deleted server fall back to the active selection.
        for index in configuration.rules.indices where configuration.rules[index].outboundID == id {
            configuration.rules[index].outboundID = nil
        }
        latencies.removeValue(forKey: id)
        persist()
    }

    /// Activating a server moves it to the front of the list (the persisted
    /// preference, and the selector default on the next tunnel start). While
    /// the tunnel is running, the provider is told to switch the live
    /// selector outbound immediately.
    func setActiveServer(_ id: TunnelServer.ID) {
        guard let index = configuration.servers.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let server = configuration.servers.remove(at: index)
        configuration.servers.insert(server, at: 0)
        persist()
        if status == .connected {
            Task { await sendOutboundSelection(id) }
        }
    }

    private func sendOutboundSelection(_ id: TunnelServer.ID) async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("select \(id.uuidString)".utf8)) { _ in }
    }

    // MARK: - Groups

    func addGroup(_ group: PolicyGroup) {
        configuration.groups.append(group)
        persist()
    }

    func updateGroup(_ group: PolicyGroup) {
        guard let index = configuration.groups.firstIndex(where: { $0.id == group.id }) else { return }
        configuration.groups[index] = group
        persist()
    }

    func deleteGroup(_ id: PolicyGroup.ID) {
        configuration.groups.removeAll { $0.id == id }
        // A member may be another group, so the id has to leave both places or
        // the remaining group keeps a member that resolves to nothing.
        for index in configuration.groups.indices {
            configuration.groups[index].memberIDs.removeAll { $0 == id }
        }
        for index in configuration.rules.indices where configuration.rules[index].outboundID == id {
            configuration.rules[index].outboundID = nil
        }
        persist()
    }

    /// Selecting a member of a `select` group moves it to the front of the
    /// member list (the persisted preference, and the group's default on the
    /// next tunnel start). While connected, the provider is told to switch
    /// the live group selection immediately.
    func setGroupMember(group: PolicyGroup.ID, member: TunnelServer.ID) {
        guard let index = configuration.groups.firstIndex(where: { $0.id == group }),
              configuration.groups[index].kind == .select,
              let memberIndex = configuration.groups[index].memberIDs.firstIndex(of: member),
              memberIndex != 0
        else { return }
        let id = configuration.groups[index].memberIDs.remove(at: memberIndex)
        configuration.groups[index].memberIDs.insert(id, at: 0)
        persist()
        if status == .connected {
            Task {
                guard let session = manager?.connection as? NETunnelProviderSession else { return }
                try? session.sendProviderMessage(
                    Data("select \(group.uuidString) \(member.uuidString)".utf8)) { _ in }
            }
        }
    }

    /// Latest engine-reported state for one group, if the tunnel is running.
    func groupState(for id: PolicyGroup.ID) -> PolicyGroupState? {
        groupStates.first { $0.tag == id.uuidString }
    }

    // MARK: - Live traffic stats

    /// While connected, polls the provider once a second for its latest
    /// engine stats snapshot so the UI can show live counters.
    private func updateStatsPolling() {
        if status == .connected {
            guard statsTask == nil else { return }
            statsTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    await self?.pollStats()
                    await self?.pollGroups()
                    await self?.pollConnections()
                    // The extension samples once a minute, so asking at the
                    // same rate would only fetch a reading already in hand.
                    if tick.isMultiple(of: 60) {
                        await self?.pollMemory()
                    }
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            statsTask?.cancel()
            statsTask = nil
            traffic = nil
            groupStates = []
            connections = []
            memory = nil
        }
    }

    private func pollStats() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("stats".utf8)) { reply in
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let response, let stats = try? JSONDecoder().decode(CoreStats.self, from: response) else {
            return
        }
        traffic = stats
    }

    private func pollGroups() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("groups".utf8)) { reply in
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let response, let states = try? JSONDecoder().decode([PolicyGroupState].self, from: response) else {
            return
        }
        groupStates = states
    }

    private func pollConnections() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("connections".utf8)) { reply in
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let response,
              let list = try? JSONDecoder().decode([EngineConnection].self, from: response)
        else { return }
        connections = list
    }

    private func pollMemory() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("memory".utf8)) { reply in
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let response, let trace = try? JSONDecoder().decode(MemoryTrace.self, from: response) else {
            return
        }
        memory = trace.latest
    }

    /// Asks the engine to close one live connection.
    func closeConnection(_ id: String) {
        connections.removeAll { $0.id == id }
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("close \(id)".utf8)) { _ in }
    }

    // MARK: - DNS

    func updateDNS(resolvers: [DNSResolver], hosts: [DNSHostMapping],
                   fakeIPEnabled: Bool, fakeIPExclusions: [String]) {
        configuration.dnsResolvers = resolvers.isEmpty ? [DNSResolver(server: "1.1.1.1")] : resolvers
        configuration.dnsHosts = hosts
        configuration.fakeIPEnabled = fakeIPEnabled
        configuration.fakeIPExclusions = fakeIPExclusions
        persist()
    }

    // MARK: - Rules

    func updateRules(_ rules: [RoutingRule]) {
        configuration.rules = rules
        persist()
    }

    func moveRule(_ rule: RoutingRule, up: Bool) {
        guard let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard configuration.rules.indices.contains(target) else { return }
        configuration.rules.swapAt(index, target)
        persist()
    }

    func updateRuleSets(_ sets: [RemoteRuleSet]) {
        configuration.ruleSets = sets
        persist()
    }

    // MARK: - Import

    /// Reads a document and puts it where it belongs. The two destinations are
    /// kept behind distinct methods rather than one call with a flag, because
    /// only one of them replaces what the user is looking at: a whole
    /// configuration becomes its own profile, and a plain list of entries is
    /// appended to the profile already active.
    @discardableResult
    func importText(fromText text: String) -> ImportOutcome {
        if let report = importConfiguration(fromText: text) {
            return .configuration(report)
        }
        return .servers(added: importServers(fromText: text))
    }

    /// Turns a document into a new profile and makes it active. Nil when the
    /// text is not a configuration at all, so the caller can fall back to the
    /// entry reader. A document that *is* one but names no servers still
    /// returns a report, carrying the reason no profile was created.
    @discardableResult
    func importConfiguration(fromText text: String) -> ImportReport? {
        guard let parsed = ConfigurationImport.parse(text) else { return nil }
        return adopt(parsed, subscription: nil, fallbackName: nil).report
    }

    /// Adds entries parsed from share-link text, skipping repeats both against
    /// the profile and within the batch. Returns the number actually added.
    @discardableResult
    func importServers(fromText text: String) -> Int {
        var seen = Set(configuration.servers.map(Self.identity))
        let fresh = ServerImport.parse(text).filter { seen.insert(Self.identity($0)).inserted }
        guard !fresh.isEmpty else { return 0 }
        configuration.servers.append(contentsOf: fresh)
        persist()
        return fresh.count
    }

    /// Fetches a document and creates a profile from it that keeps itself
    /// current. The profile is created even when the source said nothing about
    /// the account, so a source that only serves a list of entries still works.
    @discardableResult
    func importSubscription(urlString: String, interval: TimeInterval,
                            fetcher: any SubscriptionFetching = SubscriptionFetcher()) async
        -> ImportOutcome {
        guard !isRefreshingSubscription else { return .failure("Another update is already running.") }
        isRefreshingSubscription = true
        defer { isRefreshingSubscription = false }

        let now = Date()
        let fetched: SubscriptionFetchResult
        do {
            fetched = try await fetcher.fetch(urlString, now: now)
        } catch {
            return .failure(Self.describe(error))
        }
        guard let parsed = parseSubscriptionBody(fetched.text) else {
            return .failure("The source returned nothing this app could read.")
        }
        let subscription = Subscription(
            url: urlString,
            interval: max(interval, Self.minimumInterval),
            lastUpdated: now,
            lastError: nil,
            userInfo: fetched.userInfo)
        let outcome = adopt(parsed, subscription: subscription,
                            fallbackName: fetched.suggestedName
                                ?? SubscriptionFetcher.hostLabel(urlString))
        guard outcome.created else {
            return .failure("The source returned nothing this app could read.")
        }
        return .configuration(outcome.report)
    }

    /// Re-reads every profile whose interval has elapsed. Called when the app
    /// comes forward, which is the only refresh cadence that needs no
    /// background scheduling.
    func refreshDueSubscriptions(now: Date = Date(),
                                 fetcher: any SubscriptionFetching = SubscriptionFetcher()) async {
        guard !isRefreshingSubscription else { return }
        isRefreshingSubscription = true
        defer { isRefreshingSubscription = false }
        let due = profiles.filter { profile in
            profile.subscription.map { Self.isDue($0, now: now) } ?? false
        }.map(\.id)
        for id in due {
            await performRefresh(for: id, force: false, now: now, fetcher: fetcher)
        }
    }

    /// Re-reads one profile's source. A failure records why and leaves the
    /// servers alone: a source that cannot be reached must not cost the user
    /// the entries it already gave them.
    func refreshSubscription(for profileID: TunnelProfile.ID, force: Bool = false,
                             now: Date = Date(),
                             fetcher: any SubscriptionFetching = SubscriptionFetcher()) async {
        guard !isRefreshingSubscription else { return }
        isRefreshingSubscription = true
        defer { isRefreshingSubscription = false }
        await performRefresh(for: profileID, force: force, now: now, fetcher: fetcher)
    }

    /// Stops keeping the active profile current, keeping what it last brought
    /// in.
    func detachSubscription() {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }),
              profiles[index].subscription != nil else { return }
        profiles[index].subscription = nil
        save()
    }

    /// A document with a source behind it is usually a whole configuration,
    /// but share-link sources are common enough that a plain list has to work
    /// too.
    private func parseSubscriptionBody(_ text: String) -> ConfigurationImportResult? {
        if let parsed = ConfigurationImport.parse(text) { return parsed }
        let servers = ServerImport.parse(text)
        guard !servers.isEmpty else { return nil }
        var report = ImportReport()
        report.serversImported = servers.count
        return ConfigurationImportResult(
            configuration: TunnelConfiguration(servers: servers, mtu: 1500),
            report: report,
            name: nil)
    }

    /// Creates a profile from a parsed document, or explains why it could not.
    /// A document that names no servers is reported rather than turned into an
    /// empty profile the user then has to delete.
    private func adopt(_ parsed: ConfigurationImportResult, subscription: Subscription?,
                       fallbackName: String?) -> (report: ImportReport, created: Bool) {
        var report = parsed.report
        guard !parsed.configuration.servers.isEmpty else {
            report.notices.append(ImportNotice(
                severity: .dropped,
                section: .servers,
                detail: "The document names no servers, so no profile was created."))
            return (report, false)
        }
        // The outgoing profile is written as it stands before the switch, the
        // same way switchProfile does it.
        persist()
        let profile = TunnelProfile(name: uniqueProfileName(parsed.name ?? fallbackName),
                                    configuration: parsed.configuration,
                                    subscription: subscription)
        profiles.append(profile)
        activeProfileID = profile.id
        configuration = profile.configuration
        latencies.removeAll()
        save()
        return (report, true)
    }

    /// A name that is not already taken, so two imports of the same document
    /// can be told apart in the switcher.
    private func uniqueProfileName(_ preferred: String?) -> String {
        let trimmed = (preferred ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported Configuration" : trimmed
        let existing = Set(profiles.map(\.name))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func performRefresh(for profileID: TunnelProfile.ID, force: Bool, now: Date,
                                fetcher: any SubscriptionFetching) async {
        guard let start = profiles.firstIndex(where: { $0.id == profileID }),
              let subscription = profiles[start].subscription,
              force || Self.isDue(subscription, now: now)
        else { return }

        let fetched: SubscriptionFetchResult
        do {
            fetched = try await fetcher.fetch(subscription.url, now: now)
        } catch {
            recordSubscriptionError(Self.describe(error), for: profileID)
            return
        }
        // The profile may have been deleted, or its source removed, while the
        // fetch was out.
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].subscription != nil else { return }
        guard let parsed = parseSubscriptionBody(fetched.text),
              !parsed.configuration.servers.isEmpty else {
            recordSubscriptionError("The source returned nothing this app could read.",
                                    for: profileID)
            return
        }
        profiles[index].configuration = parsed.configuration
        profiles[index].subscription?.lastUpdated = now
        profiles[index].subscription?.lastError = nil
        // A source that stops reporting account usage is no reason to forget
        // what it last said.
        if let userInfo = fetched.userInfo {
            profiles[index].subscription?.userInfo = userInfo
        }
        if activeProfileID == profileID {
            configuration = parsed.configuration
        }
        save()
    }

    /// Deliberately leaves `lastUpdated` alone, so a profile that failed stays
    /// due and is retried at the next opportunity.
    private func recordSubscriptionError(_ message: String, for profileID: TunnelProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].subscription != nil else { return }
        profiles[index].subscription?.lastError = message
        save()
    }

    private static func isDue(_ subscription: Subscription, now: Date) -> Bool {
        guard let lastUpdated = subscription.lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= subscription.interval
    }

    private static func describe(_ error: Error) -> String {
        (error as? SubscriptionFetchError)?.errorDescription ?? error.localizedDescription
    }

    private static func identity(_ server: TunnelServer) -> String {
        "\(server.host):\(server.port):\(server.transport)"
    }

    /// The shortest interval a source may be re-read at, so a stray value
    /// cannot turn into a fetch loop.
    private static let minimumInterval: TimeInterval = 3600

    // MARK: - Engine logs

    /// Asks the provider process for its captured engine log lines.
    /// Returns nil when the session cannot be reached at all (e.g. the
    /// profile is not installed); an empty string means the provider has
    /// nothing captured yet.
    func fetchEngineLogs() async -> String? {
        do {
            let manager = try await loadOrCreateManager()
            guard let session = manager.connection as? NETunnelProviderSession else { return nil }
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(Data("logs".utf8)) { response in
                        let text = response.flatMap { String(data: $0, encoding: .utf8) }
                        continuation.resume(returning: text ?? "")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Latency

    func checkLatency(for id: TunnelServer.ID) async {
        guard let server = configuration.servers.first(where: { $0.id == id }) else { return }
        latencies[id] = await ServerLatency.measure(host: server.host, port: server.port)
    }

    func checkAllLatencies() async {
        isTestingLatency = true
        defer { isTestingLatency = false }
        let servers = configuration.servers
        let results = await withTaskGroup(of: (TunnelServer.ID, Double?).self) { group in
            for server in servers {
                group.addTask {
                    let latency = await ServerLatency.measure(host: server.host, port: server.port)
                    return (server.id, latency)
                }
            }
            var collected: [TunnelServer.ID: Double] = [:]
            for await (id, latency) in group {
                if let latency {
                    collected[id] = latency
                }
            }
            return collected
        }
        latencies = results
    }

    private func persist() {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[index].configuration = configuration
        save()
    }

    /// Writes the profile set as it stands. Split from `persist()` because a
    /// subscription refresh changes a profile that need not be the active one,
    /// and mirroring the active configuration over it would undo the refresh.
    private func save() {
        do {
            try store.saveProfileSet(ProfileSet(profiles: profiles, activeProfileID: activeProfileID))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Profiles

    /// Switching profiles updates the stored active configuration immediately;
    /// a running tunnel keeps its current engine config until reconnected.
    func switchProfile(to id: TunnelProfile.ID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        persist()
        activeProfileID = id
        configuration = profiles.first { $0.id == id }?.configuration ?? .default
        latencies.removeAll()
        persist()
    }

    @discardableResult
    func addProfile(named name: String) -> TunnelProfile.ID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let profile = TunnelProfile(name: trimmed)
        profiles.append(profile)
        persist()
        return profile.id
    }

    func deleteActiveProfile() {
        guard profiles.count > 1, let current = activeProfile else { return }
        profiles.removeAll { $0.id == current.id }
        let next = profiles[profiles.startIndex]
        activeProfileID = next.id
        configuration = next.configuration
        latencies.removeAll()
        persist()
    }

    private static let profileTitle = "Waypo"

#if os(macOS)
    private static let tunnelBundleID = "org.waypo.mac.tunnel"
#else
    private static let tunnelBundleID = "org.waypo.ios.tunnel"
#endif

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: { $0.localizedDescription == Self.profileTitle }) {
            observeStatus(of: existing)
            manager = existing
            return existing
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = configuration.servers.first?.host
        proto.providerConfiguration = ["configVersion": 1]

        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = Self.profileTitle
        newManager.isEnabled = true
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()

        observeStatus(of: newManager)
        manager = newManager
        return newManager
    }

    private func observeStatus(of manager: NETunnelProviderManager?) {
        guard manager != nil, !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc
    nonisolated private func statusDidChange(_ notification: Notification) {
        Task { @MainActor in
            status = manager?.connection.status ?? .invalid
        }
    }
}
