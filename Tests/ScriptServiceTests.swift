import Foundation
import Testing

/// Runs `body` against a store backed by a suite private to this test, then
/// removes the domain. Never touches `group.org.waypo`.
@MainActor
private func withService(_ body: (ScriptStore) async throws -> Void) async rethrows {
    let name = "org.waypo.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: name) }
    try await body(ScriptStore(suiteName: name))
}

/// The service's own state is main-actor isolated and can be read only there,
/// so its expectation polls on the main actor rather than through the generic
/// `waitUntil`, which takes a `@Sendable` closure.
@MainActor
private func waitFor(_ condition: @MainActor () -> Bool,
                     timeout: TimeInterval = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Suite
@MainActor
struct ScriptServiceTests {
    // MARK: - Editing

    @Test
    func savedScriptsSurviveANewService() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let script = Script(name: "Kept", source: "$done('ok')")
            service.save(script)

            let reloaded = ScriptService(store: store, runner: FakeScriptRunner())
            reloaded.load()
            #expect(reloaded.scripts.map(\.id) == [script.id])
            #expect(reloaded.scripts.first?.source == "$done('ok')")
        }
    }

    @Test
    func savingTheSameIdentifierUpdatesInPlace() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            var script = Script(name: "Before")
            service.save(script)
            script.name = "After"
            service.save(script)
            #expect(service.scripts.count == 1)
            #expect(service.scripts.first?.name == "After")
        }
    }

    @Test
    func deletingAScriptRemovesItsStoredValuesToo() async throws {
        try await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let script = Script(name: "Gone")
            service.save(script)
            try store.savePersistentStore(["k": "v"], for: script.id)

            service.delete(script.id)
            #expect(service.scripts.isEmpty)
            #expect(store.persistentStore(for: script.id).isEmpty)

            let reloaded = ScriptService(store: store, runner: FakeScriptRunner())
            reloaded.load()
            #expect(reloaded.scripts.isEmpty)
        }
    }

    @Test
    func aCronScriptWithNoScheduleIsFlagged() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let broken = Script(name: "Broken", kind: .cron)
            service.save(broken)
            service.save(Script(name: "Fine", kind: .cron, schedule: .interval(seconds: 60)))
            service.save(Script(name: "Manual"))
            #expect(service.scriptsWithInvalidSchedule.map(\.id) == [broken.id])
        }
    }

    // MARK: - The import sanitiser

    @Test
    func anImportedScriptLandsDisabled() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            service.save(Script(name: "Fetched", isEnabled: true, origin: .imported))
            #expect(service.scripts.first?.isEnabled == false)
        }
    }

    @Test
    func anImportedScriptCannotBeEnabled() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let script = Script(name: "Fetched", isEnabled: true, origin: .imported)
            service.save(script)
            service.setEnabled(true, for: script.id)
            #expect(service.scripts.first?.isEnabled == false)
        }
    }

    // MARK: - Running

    @Test
    func aRunIsRecordedAndAdvancesTheScript() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let script = Script(name: "Once")
            service.save(script)

            let now = Date()
            let record = await service.run(script.id, trigger: .manual, at: now)
            #expect(record?.scriptID == script.id)
            #expect(record?.scriptName == "Once")
            #expect(record?.trigger == .manual)
            #expect(record?.outcome == .success)
            #expect(service.history.count == 1)
            #expect(service.scripts.first?.lastOutcome == .success)
            #expect(service.scripts.first?.lastRunAt != nil)
        }
    }

    @Test
    func onlyAScheduledRunMovesTheAnchor() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let now = Date()
            let script = Script(name: "Anchored", kind: .cron, schedule: .interval(seconds: 60),
                                createdAt: now.addingTimeInterval(-600))
            service.save(script, at: now)

            _ = await service.run(script.id, trigger: .manual, at: now)
            // A person pressing run must not push the next scheduled fire back.
            #expect(service.scripts.first?.lastScheduledFireAt == nil)

            _ = await service.run(script.id, trigger: .schedule, at: now)
            let anchor = service.scripts.first?.lastScheduledFireAt
            #expect(anchor != nil)
            #expect(abs((anchor ?? .distantPast).timeIntervalSince(now)) < 0.01)
        }
    }

    @Test
    func anUnknownScriptIsRefused() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            let record = await service.run(UUID(), trigger: .manual)
            #expect(record == nil)
            #expect(runner.runs.isEmpty)
        }
    }

    @Test
    func aDisabledScriptOnlyRunsWhenAskedDirectly() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            let script = Script(name: "Off", isEnabled: false)
            service.save(script)

            let scheduled = await service.run(script.id, trigger: .schedule)
            let manual = await service.run(script.id, trigger: .manual)
            #expect(scheduled == nil)
            #expect(manual != nil)
            #expect(runner.runs.count == 1)
        }
    }

    @Test
    func aSkippedRunPausesTheService() async {
        await withService { store in
            let runner = FakeScriptRunner()
            runner.result = ScriptResult(outcome: .skipped, output: "stopped", duration: 0)
            let service = ScriptService(store: store, runner: runner)
            let script = Script(name: "Stopped")
            service.save(script)

            #expect(!service.isPaused)
            _ = await service.run(script.id, trigger: .schedule)
            #expect(service.isPaused)
            #expect(service.history.first?.outcome == .skipped)
        }
    }

    @Test
    func aSecondRunIsRefusedWhileOneIsInFlight() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            let script = Script(name: "Slow")
            service.save(script)

            runner.hold()
            let first = Task { await service.run(script.id, trigger: .manual) }
            let started = await waitFor { service.runningScriptIDs.contains(script.id) }
            #expect(started)

            let second = await service.run(script.id, trigger: .manual)
            #expect(second == nil)
            #expect(runner.runs.count == 1)

            runner.release()
            let outcome = await first.value
            #expect(outcome != nil)
            #expect(service.runningScriptIDs.isEmpty)
        }
    }

    // MARK: - History

    @Test
    func historyIsBoundedAndNewestFirst() async {
        await withService { store in
            let service = ScriptService(store: store, runner: FakeScriptRunner())
            let script = Script(name: "Repeat")
            service.save(script)

            for _ in 0..<(ScriptLimits.history + 5) {
                _ = await service.run(script.id, trigger: .manual)
            }
            #expect(service.history.count == ScriptLimits.history)

            let reloaded = ScriptService(store: store, runner: FakeScriptRunner())
            reloaded.load()
            #expect(reloaded.history.count == ScriptLimits.history)
            let stamps = reloaded.history.map(\.startedAt)
            #expect(stamps == stamps.sorted(by: >))
        }
    }

    // MARK: - Scheduling

    @Test
    func aDueScriptFiresOnceAndNotTwice() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            let now = Date()
            let script = Script(name: "Due", kind: .cron, schedule: .interval(seconds: 60),
                                createdAt: now.addingTimeInterval(-600))
            service.save(script, at: now)

            service.tick(now: now)
            let fired = await waitFor { runner.runs.count == 1 }
            #expect(fired)
            #expect(service.scripts.first?.lastScheduledFireAt != nil)

            // The anchor moved synchronously, so the same instant is already spent.
            service.tick(now: now)
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.count == 1)
        }
    }

    @Test
    func aScriptThatIsNotDueIsLeftAlone() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            let now = Date()
            service.save(Script(name: "Later", kind: .cron, schedule: .interval(seconds: 3600),
                                createdAt: now), at: now)
            service.save(Script(name: "Off", kind: .cron, schedule: .interval(seconds: 60),
                                isEnabled: false, createdAt: now.addingTimeInterval(-600)),
                         at: now)

            service.tick(now: now)
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.isEmpty)
        }
    }

    // MARK: - Events

    @Test
    func onlyRealTransitionsFireEvents() async throws {
        try await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            service.save(Script(name: "On connect", kind: .event, event: .tunnelConnected))

            let controller = TunnelController(
                store: TunnelStore(suiteName: "org.waypo.tests.\(UUID().uuidString)"))
            service.bind(to: controller)
            let transition = try #require(controller.onStatusTransition)

            // Steps on the way in and out are not arrivals or departures.
            transition(.connecting, .connecting)
            transition(.connecting, .reasserting)
            transition(.disconnected, .connecting)
            transition(.invalid, .disconnected)
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(runner.runs.isEmpty)

            transition(.connecting, .connected)
            let arrived = await waitFor { runner.runs.count == 1 }
            #expect(arrived)
            #expect(runner.runs.first?.trigger == .event)

            // Already connected, so the same value again is not a new arrival.
            transition(.connected, .connected)
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.count == 1)
        }
    }

    @Test
    func aReassertIsNotADisconnect() async throws {
        try await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            service.save(Script(name: "On drop", kind: .event, event: .tunnelDisconnected))

            let controller = TunnelController(
                store: TunnelStore(suiteName: "org.waypo.tests.\(UUID().uuidString)"))
            service.bind(to: controller)
            let transition = try #require(controller.onStatusTransition)

            // Recovering is not leaving, and neither is on the way out.
            transition(.connected, .reasserting)
            transition(.reasserting, .connected)
            transition(.connected, .disconnecting)
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.isEmpty)

            transition(.disconnecting, .disconnected)
            let dropped = await waitFor { runner.runs.count == 1 }
            #expect(dropped)
        }
    }

    @Test
    func aLaunchScriptFiresOncePerProcess() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            service.save(Script(name: "On launch", kind: .event, event: .appLaunched))

            service.noteAppLaunched()
            let launched = await waitFor { runner.runs.count == 1 }
            #expect(launched)

            service.noteAppLaunched()
            service.noteAppForeground()
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.count == 1)
        }
    }

    @Test
    func anEventScriptIgnoresTheOtherEvents() async {
        await withService { store in
            let runner = FakeScriptRunner()
            let service = ScriptService(store: store, runner: runner)
            service.save(Script(name: "On launch", kind: .event, event: .appLaunched))
            service.save(Script(name: "Scheduled", kind: .cron, schedule: .interval(seconds: 60)))

            service.fire(.tunnelDisconnected)
            service.noteAppForeground()
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(runner.runs.isEmpty)
        }
    }

    // MARK: - The environment source

    @Test
    func theEnvironmentIsReadAtEachRun() async {
        await withService { store in
            let runner = FakeScriptRunner()
            var calls = 0
            let service = ScriptService(store: store, runner: runner) {
                calls += 1
                return .empty
            }
            let script = Script(name: "Snapshot")
            service.save(script)

            _ = await service.run(script.id, trigger: .manual)
            _ = await service.run(script.id, trigger: .manual)
            #expect(calls == 2)
        }
    }
}
