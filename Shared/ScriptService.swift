import Foundation
import NetworkExtension
import Observation

/// Owns the script list, runs them, and keeps the run history.
///
/// Scripts run in the app process only: nothing here is reached from the
/// packet tunnel provider, and no schedule or event fires unless the app is
/// running. A one-shot controller built for a shortcut never binds, so no
/// event fires from that path either.
@MainActor
@Observable
final class ScriptService {
    /// How often the scheduler looks for work while the app is running.
    static let tickInterval: TimeInterval = 30

    private(set) var scripts: [Script] = []
    /// Newest first, capped by the store.
    private(set) var history: [ScriptRunRecord] = []
    /// Scripts with a run in flight, so one script never runs twice at once.
    private(set) var runningScriptIDs: Set<UUID> = []
    /// True once runs were stopped for this process because too many had to be
    /// abandoned. Only relaunching clears it.
    private(set) var isPaused = false
    private(set) var lastError: String?

    /// Cron scripts with nothing to fire on, so the list can flag them.
    var scriptsWithInvalidSchedule: [Script] {
        scripts.filter { $0.kind == .cron && $0.schedule == nil }
    }

    private let store: ScriptStore
    private let runner: any ScriptRunning
    private let calendar: Calendar
    private let environment: @MainActor () -> ScriptEnvironment
    private var tickTask: Task<Void, Never>?
    private var hasFiredLaunch = false

    init(store: ScriptStore = ScriptStore(),
         runner: any ScriptRunning,
         calendar: Calendar = .current,
         environment: @escaping @MainActor () -> ScriptEnvironment = { .empty }) {
        self.store = store
        self.runner = runner
        self.calendar = calendar
        self.environment = environment
    }

    // MARK: - Loading

    func load() {
        scripts = store.loadScripts()
        history = store.loadHistory()
    }

    // MARK: - Editing

    func save(_ script: Script, at date: Date = Date()) {
        var updated = script
        updated.updatedAt = date
        if let index = scripts.firstIndex(where: { $0.id == updated.id }) {
            scripts[index] = updated
        } else {
            scripts.append(updated)
        }
        persist()
    }

    /// History is deliberately kept: each record carries the name the script
    /// had when it ran, so it still reads after the script is gone.
    func delete(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        store.deletePersistentStore(for: id)
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].isEnabled = enabled
        scripts[index].updatedAt = Date()
        persist()
    }

    // MARK: - Running

    /// Starts a run and returns its history record, or nil when the script is
    /// gone, already running, or not allowed to fire this way.
    @discardableResult
    func run(_ id: UUID, trigger: ScriptRunRecord.Trigger,
             at date: Date = Date()) async -> ScriptRunRecord? {
        guard let script = scripts.first(where: { $0.id == id }) else { return nil }
        // A manual run is the person asking directly, so it goes ahead even
        // when the script is switched off.
        guard script.isEnabled || trigger == .manual else { return nil }
        guard !runningScriptIDs.contains(id) else { return nil }
        runningScriptIDs.insert(id)
        defer { runningScriptIDs.remove(id) }

        let result = await runner.run(script, trigger: trigger, environment: environment())
        if result.outcome == .skipped { isPaused = true }

        if let index = scripts.firstIndex(where: { $0.id == id }) {
            scripts[index].lastRunAt = date
            scripts[index].lastOutcome = result.outcome
            // Only a scheduled run moves the anchor the scheduler measures
            // from, so a manual run does not push the next fire back.
            if trigger == .schedule {
                scripts[index].lastScheduledFireAt = date
            }
            persist()
        }

        let record = ScriptRunRecord(scriptID: id, scriptName: script.name, trigger: trigger,
                                     startedAt: date, duration: result.duration,
                                     outcome: result.outcome, output: result.output,
                                     log: result.log)
        history.insert(record, at: 0)
        if history.count > ScriptLimits.history {
            history.removeLast(history.count - ScriptLimits.history)
        }
        persistHistory()
        return record
    }

    func runNow(_ id: UUID, at date: Date = Date()) {
        Task { await run(id, trigger: .manual, at: date) }
    }

    /// Fires everything whose schedule has come due.
    ///
    /// The anchor moves before the run starts, so a run that outlasts the
    /// interval cannot be picked up a second time while it is still going.
    func tick(now: Date = Date()) {
        let due = ScriptScheduler.due(scripts, now: now, calendar: calendar)
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.id))
        for index in scripts.indices where ids.contains(scripts[index].id) {
            scripts[index].lastScheduledFireAt = now
        }
        persist()
        for id in ids {
            Task { await run(id, trigger: .schedule, at: now) }
        }
    }

    /// Runs every event script subscribed to this moment.
    func fire(_ event: ScriptEvent, at date: Date = Date()) {
        for script in scripts where script.kind == .event && script.event == event {
            Task { await run(script.id, trigger: .event, at: date) }
        }
    }

    /// Once per process: coming back to the foreground is a separate moment,
    /// so a launch script must not repeat every time the app is reopened.
    func noteAppLaunched(at date: Date = Date()) {
        guard !hasFiredLaunch else { return }
        hasFiredLaunch = true
        fire(.appLaunched, at: date)
    }

    func noteAppForeground(at date: Date = Date()) {
        fire(.appForeground, at: date)
    }

    /// Follows the connection so event scripts fire on real transitions.
    ///
    /// A reassert is the tunnel recovering in place, so it is not reported at
    /// all: telling a script the connection came back when it never went away
    /// is as wrong as telling it the connection went away. Everything else
    /// between the two is a step inside one of them.
    func bind(to controller: TunnelController) {
        controller.onStatusTransition = { [weak self] from, to in
            guard let self else { return }
            if to == .connected, from != .connected, from != .reasserting {
                self.fire(.tunnelConnected)
            } else if !Self.isIdle(from), Self.isIdle(to) {
                self.fire(.tunnelDisconnected)
            }
        }
    }

    /// Nothing is happening and nothing is on its way: the only two states a
    /// connection can be down in.
    private static func isIdle(_ status: NEVPNStatus) -> Bool {
        status == .disconnected || status == .invalid
    }

    // MARK: - Lifecycle

    func start() {
        load()
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try store.saveScripts(scripts)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Read back, so the rule about imported scripts lives in one place
        // and the list shows its result rather than a second copy of it.
        scripts = store.loadScripts()
    }

    private func persistHistory() {
        do {
            try store.saveHistory(history)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        history = store.loadHistory()
    }
}
