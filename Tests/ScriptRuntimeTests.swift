import Foundation
import Testing

private func makeScript(_ source: String, id: UUID = UUID(), argument: String? = nil) -> Script {
    Script(id: id, name: "Test", source: source, argument: argument)
}

private func runtime(_ host: FakeScriptHost, manual: TimeInterval = 5,
                     scheduled: TimeInterval = 5) -> ScriptRuntime {
    ScriptRuntime(host: host, manualBudget: manual, scheduledBudget: scheduled)
}

/// A request that can never be answered, so only the run's budget can end it.
private let hangingRequest = "$httpClient.get('https://example.test/');"

@Suite
struct ScriptRuntimeTests {
    // MARK: - Finishing

    @Test
    func doneWithAStringIsTheOutput() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done('finished')"),
                                            trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(result.output == "finished")
    }

    @Test
    func doneWithAValueIsSerialized() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done({ ok: true, n: 2 })"),
                                            trigger: .manual, environment: .empty)
        #expect(result.output == #"{"ok":true,"n":2}"#)
    }

    @Test
    func doneWithoutAValueStillSucceeds() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done()"),
                                            trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(result.output == nil)
    }

    @Test
    func theFirstDoneDecides() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done('first'); $done('second');"),
                                            trigger: .manual, environment: .empty)
        #expect(result.output == "first")
    }

    @Test
    func nothingAfterDoneIsRecorded() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("$done('first'); console.log('after the end');"),
            trigger: .manual, environment: .empty)
        #expect(result.output == "first")
        #expect(result.log.isEmpty)
    }

    @Test
    func aScriptWithNoDoneSucceedsWithNoOutput() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("var unused = 1;"),
                                            trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(result.output == nil)
    }

    // MARK: - Console

    @Test
    func consoleLevelsArePrefixed() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("console.log('a'); console.warn('b'); console.error('c'); $done('ok');"),
            trigger: .manual, environment: .empty)
        #expect(result.log == ["a", "[warn] b", "[error] c"])
    }

    @Test
    func consoleJoinsItsArguments() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("console.log('a', 1, { b: 2 }); $done('ok');"),
            trigger: .manual, environment: .empty)
        #expect(result.log == [#"a 1 {"b":2}"#])
    }

    @Test
    func theRunLogIsCapped() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("for (var i = 0; i < 500; i++) { console.log('line ' + i); } $done('ok');"),
            trigger: .manual, environment: .empty)
        #expect(!result.log.isEmpty)
        #expect(result.log.count < 500)
    }

    // MARK: - Isolation

    @Test
    func theArgumentIsAvailable() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done($argument)", argument: "given"),
                                            trigger: .manual, environment: .empty)
        #expect(result.output == "given")
    }

    @Test
    func topLevelStateDoesNotSurviveBetweenRuns() async {
        let host = FakeScriptHost()
        let run = runtime(host)
        let id = UUID()
        _ = await run.run(makeScript("var leaked = 1; $done('ok');", id: id),
                          trigger: .manual, environment: .empty)
        let second = await run.run(makeScript("$done(String(typeof leaked));", id: id),
                                   trigger: .manual, environment: .empty)
        #expect(second.output == "undefined")
    }

    @Test
    func aSyntaxErrorIsReportedWithItsMessage() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("this is not javascript("),
                                             trigger: .manual, environment: .empty)
        #expect(result.outcome == .error)
        #expect(result.output?.isEmpty == false)
    }

    @Test
    func aThrownErrorIsReportedWithItsMessage() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("throw new Error('boom');"),
                                             trigger: .manual, environment: .empty)
        #expect(result.outcome == .error)
        #expect(result.output?.contains("boom") == true)
    }

    @Test
    func aLongOutputIsTruncated() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(makeScript("$done('x'.repeat(40000));"),
                                             trigger: .manual, environment: .empty)
        let output = result.output ?? ""
        #expect(!output.isEmpty)
        #expect(output.utf8.count <= ScriptLimits.outputBytes)
    }

    // MARK: - Persistent store

    @Test
    func theStoreRoundTripsWithinARun() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("$persistentStore.write('one', 'key'); $done($persistentStore.read('key'));"),
            trigger: .manual, environment: .empty)
        #expect(result.output == "one")
    }

    @Test
    func theStoreSurvivesBetweenRuns() async {
        let host = FakeScriptHost()
        let run = runtime(host)
        let id = UUID()
        _ = await run.run(makeScript("$persistentStore.write('one', 'key'); $done('ok');", id: id),
                          trigger: .manual, environment: .empty)
        #expect(host.stored(id) == ["key": "one"])
        let second = await run.run(makeScript("$done($persistentStore.read('key'));", id: id),
                                   trigger: .manual, environment: .empty)
        #expect(second.output == "one")
    }

    @Test
    func aRefusedWriteReportsFalseAndChangesNothing() async {
        let host = FakeScriptHost()
        host.refusesWrites = true
        let id = UUID()
        let result = await runtime(host).run(
            makeScript("$done(String($persistentStore.write('v', 'k')));", id: id),
            trigger: .manual, environment: .empty)
        #expect(result.output == "false")
        #expect(host.stored(id).isEmpty)
    }

    @Test
    func writingNothingDeletes() async {
        let host = FakeScriptHost()
        let id = UUID()
        host.seed(["k": "v"], for: id)
        let result = await runtime(host).run(
            makeScript("""
            $persistentStore.write(null, 'k');
            $done($persistentStore.read('k') === null ? 'gone' : 'present');
            """, id: id),
            trigger: .manual, environment: .empty)
        #expect(result.output == "gone")
        #expect(host.stored(id).isEmpty)
    }

    // MARK: - Environment

    @Test
    func theEnvironmentSnapshotIsExposed() async {
        let host = FakeScriptHost()
        let server = ScriptEnvironment.Server(id: UUID(), name: "Tokyo", transport: "vless")
        let environment = ScriptEnvironment(profile: "Personal", status: "connected",
                                            isActive: true, activeServerID: server.id,
                                            version: "1.0", servers: [server])
        let result = await runtime(host).run(
            makeScript("""
            $done([$waypo.profile, $waypo.status, String($waypo.isActive), $waypo.version,
                   $waypo.servers[0].name, $waypo.servers[0].transport,
                   String($waypo.servers[0].active)].join('/'));
            """),
            trigger: .manual, environment: environment)
        #expect(result.output == "Personal/connected/true/1.0/Tokyo/vless/true")
    }

    @Test
    func aKnownServerCanBeSelected() async {
        let host = FakeScriptHost()
        let server = ScriptEnvironment.Server(id: UUID(), name: "Tokyo", transport: "vless")
        let environment = ScriptEnvironment(profile: "Personal", status: "connected",
                                            isActive: true, activeServerID: nil,
                                            version: "1.0", servers: [server])
        let result = await runtime(host).run(
            makeScript("$done(String($waypo.selectServer('\(server.id.uuidString)')));"),
            trigger: .manual, environment: environment)
        #expect(result.output == "true")
        // The switch is queued off the run queue, so it lands a moment later.
        let switched = await waitUntil { host.switches == [server.id] }
        #expect(switched)
    }

    @Test
    func anUnknownOrMalformedServerIsRefused() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("""
            $done([String($waypo.selectServer('not-a-uuid')),
                   String($waypo.selectServer('\(UUID().uuidString)'))].join('/'));
            """),
            trigger: .manual, environment: .empty)
        #expect(result.output == "false/false")
        #expect(host.switches.isEmpty)
    }

    // MARK: - Requests

    @Test
    func aResponseReachesTheCallback() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .response(ScriptHTTPResponse(status: 200, headers: ["X-Key": "v"],
                                                           body: "hi"))
        let result = await runtime(host).run(
            makeScript("""
            $httpClient.get('https://example.test/', function (error, response, body) {
              $done([String(error), String(response.status), body, response.headers['X-Key']].join('/'));
            });
            """),
            trigger: .manual, environment: .empty)
        #expect(result.output == "null/200/hi/v")
        #expect(host.requests.count == 1)
        #expect(host.requests.first?.method == .get)
        #expect(host.requests.first?.url == "https://example.test/")
    }

    @Test
    func aPostCarriesItsHeadersAndBody() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .response(ScriptHTTPResponse(status: 201, headers: [:], body: "ok"))
        _ = await runtime(host).run(
            makeScript("""
            $httpClient.post({ url: 'https://example.test/api',
                               headers: { 'X-Key': 'v' }, body: 'payload' },
                             function (error, response, body) { $done(body); });
            """),
            trigger: .manual, environment: .empty)
        let request = host.requests.first
        #expect(request?.method == .post)
        #expect(request?.url == "https://example.test/api")
        #expect(request?.headers == ["X-Key": "v"])
        #expect(request?.body == "payload")
    }

    @Test
    func aNonSuccessStatusIsStillAResponse() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .response(ScriptHTTPResponse(status: 500, headers: [:], body: "no"))
        let result = await runtime(host).run(
            makeScript("""
            $httpClient.get('https://example.test/', function (error, response, body) {
              $done([String(error), String(response === null), String(response.status)].join('/'));
            });
            """),
            trigger: .manual, environment: .empty)
        #expect(result.output == "null/false/500")
    }

    @Test
    func aFailedRequestReachesTheCallbackAsAnError() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .failure("no route")
        let result = await runtime(host).run(
            makeScript("""
            $httpClient.get('https://example.test/', function (error, response, body) {
              $done(error + '/' + String(response === null) + '/' + String(body === null));
            });
            """),
            trigger: .manual, environment: .empty)
        #expect(result.output == "no route/true/true")
    }

    @Test
    func aRequestWithoutACallbackStillCompletes() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .response(ScriptHTTPResponse(status: 200, headers: [:], body: ""))
        let result = await runtime(host).run(makeScript("$httpClient.get('https://example.test/');"),
                                             trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(host.requests.count == 1)
    }

    @Test
    func doneInsideACallbackWins() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .response(ScriptHTTPResponse(status: 200, headers: [:], body: "hi"))
        let result = await runtime(host).run(
            makeScript("""
            $httpClient.get('https://example.test/', function (error, response, body) {
              $done('from the callback');
            });
            """),
            trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(result.output == "from the callback")
    }

    @Test
    func aRequestWithNoUrlIsRefused() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("""
            $httpClient.get({ headers: {} }, function (error, response, body) {
              $done(error + '/' + String(response === null));
            });
            """),
            trigger: .manual, environment: .empty)
        #expect(result.output == "The request had no URL./true")
        #expect(host.requests.isEmpty)
    }

    // MARK: - Notification

    @Test
    func notifyingDoesNotHoldTheRunOpen() async {
        let host = FakeScriptHost()
        let result = await runtime(host).run(
            makeScript("$notify('Title', 'Sub', 'Body'); $done('ok');"),
            trigger: .manual, environment: .empty)
        #expect(result.outcome == .success)
        #expect(result.output == "ok")
        #expect(host.notifications == [FakeScriptHost.Notification(title: "Title", subtitle: "Sub",
                                                                   body: "Body")])
        // Recorded in the log too, so it is visible even when nothing is shown.
        #expect(result.log.contains("[notify] Title"))
    }

    // MARK: - Budgets

    @Test
    func aManualRunGetsTheLongerBudget() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .never
        let started = Date()
        let result = await runtime(host, manual: 0.1, scheduled: 60)
            .run(makeScript(hangingRequest), trigger: .manual, environment: .empty)
        #expect(result.outcome == .timeout)
        #expect(result.output == ScriptRuntime.timeoutMessage(0.1))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test
    func aScheduledRunGetsTheShorterBudget() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .never
        let started = Date()
        let result = await runtime(host, manual: 60, scheduled: 0.1)
            .run(makeScript(hangingRequest), trigger: .schedule, environment: .empty)
        #expect(result.outcome == .timeout)
        #expect(result.output == ScriptRuntime.timeoutMessage(0.1))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test
    func scriptingStopsAfterEnoughRunsAreAbandoned() async {
        let host = FakeScriptHost()
        host.defaultOutcome = .never
        let run = runtime(host, manual: 0.05, scheduled: 0.05)
        for _ in 0..<ScriptRuntime.abandonedRunLimit {
            let result = await run.run(makeScript(hangingRequest),
                                       trigger: .schedule, environment: .empty)
            #expect(result.outcome == .timeout)
        }
        let skipped = await run.run(makeScript("$done('ok')"),
                                    trigger: .schedule, environment: .empty)
        #expect(skipped.outcome == .skipped)
        #expect(skipped.output == ScriptRuntime.pausedMessage)
    }

    @Test
    func oneRuntimeDoesNotPauseAnother() async {
        // A fresh runtime starts with a fresh tally, so one app session's
        // abandoned runs never carry into the next.
        let host = FakeScriptHost()
        host.defaultOutcome = .never
        _ = await runtime(host, manual: 0.05, scheduled: 0.05)
            .run(makeScript(hangingRequest), trigger: .schedule, environment: .empty)
        let other = await runtime(host).run(makeScript("$done('ok')"),
                                            trigger: .manual, environment: .empty)
        #expect(other.outcome == .success)
    }
}
