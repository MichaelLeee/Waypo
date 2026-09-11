import Foundation
import Testing

@Suite
struct ScriptModelTests {
    private static let created = Date(timeIntervalSince1970: 1_700_000_000)
    private static let ran = Date(timeIntervalSince1970: 1_700_003_600)

    private static func fullScript() -> Script {
        Script(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Nightly",
            kind: .cron,
            source: "console.log($argument)",
            argument: "hello",
            schedule: .cron(try! CronExpression.parse("30 3 * * *")),
            event: nil,
            isEnabled: true,
            origin: .user,
            createdAt: created,
            updatedAt: created,
            lastRunAt: ran,
            lastScheduledFireAt: ran,
            lastOutcome: .success
        )
    }

    @Test
    func roundTripPreservesEveryField() throws {
        let original = Self.fullScript()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Script.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func encodingUsesTheDeclaredKeys() throws {
        let data = try JSONEncoder().encode(Self.fullScript())
        let json = String(decoding: data, as: UTF8.self)
        for key in ["lastScheduledFireAt", "lastRunAt", "lastOutcome", "origin", "isEnabled"] {
            #expect(json.contains(key))
        }
    }

    @Test
    func intervalScheduleRoundTrips() throws {
        let script = Script(name: "Frequent", kind: .cron,
                            schedule: .interval(seconds: 300))
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(Script.self, from: data)
        #expect(decoded.schedule == .interval(seconds: 300))
    }

    @Test
    func missingFieldsFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(Script.self, from: Data(#"{"name":"Legacy"}"#.utf8))
        #expect(decoded.name == "Legacy")
        #expect(decoded.kind == .manual)
        #expect(decoded.source.isEmpty)
        #expect(decoded.argument == nil)
        #expect(decoded.schedule == nil)
        #expect(decoded.event == nil)
        #expect(decoded.isEnabled)
        #expect(decoded.origin == .user)
        #expect(decoded.lastRunAt == nil)
        #expect(decoded.lastScheduledFireAt == nil)
        #expect(decoded.lastOutcome == nil)
        // `updatedAt` trails `createdAt` rather than the epoch.
        #expect(decoded.updatedAt == decoded.createdAt)
    }

    @Test
    func evenANameLessBlobDecodes() throws {
        let decoded = try JSONDecoder().decode(Script.self, from: Data("{}".utf8))
        #expect(decoded.name.isEmpty)
        #expect(decoded.kind == .manual)
    }

    @Test
    func unknownEnumValuesDoNotFailTheDecode() throws {
        let json = #"""
        {"name":"Odd","kind":"http-request","event":"tunnel.sneezed",
         "origin":"somewhere","lastOutcome":"exploded"}
        """#
        let decoded = try JSONDecoder().decode(Script.self, from: Data(json.utf8))
        #expect(decoded.kind == .manual)
        #expect(decoded.event == nil)
        #expect(decoded.origin == .user)
        #expect(decoded.lastOutcome == nil)
    }

    @Test
    func unreadableScheduleLeavesTheRestIntact() throws {
        let json = #"{"name":"Half","kind":"cron","schedule":{"kind":"cron"}}"#
        let decoded = try JSONDecoder().decode(Script.self, from: Data(json.utf8))
        #expect(decoded.name == "Half")
        #expect(decoded.kind == .cron)
        #expect(decoded.schedule == nil)
    }

    @Test
    func knownEventNamesRoundTrip() throws {
        for event in ScriptEvent.allCases {
            let script = Script(name: "E", kind: .event, event: event)
            let data = try JSONEncoder().encode(script)
            let decoded = try JSONDecoder().decode(Script.self, from: data)
            #expect(decoded.event == event)
        }
    }

    @Test
    func runRecordRoundTrips() throws {
        let record = ScriptRunRecord(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            scriptID: Self.fullScript().id,
            scriptName: "Nightly",
            trigger: .schedule,
            startedAt: Self.ran,
            duration: 1.25,
            outcome: .timeout,
            output: "done",
            log: ["first", "second"]
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ScriptRunRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.trigger == .schedule)
    }

    @Test
    func runRecordDefaultsAreMinimal() throws {
        let record = ScriptRunRecord(scriptID: UUID(), scriptName: "S", trigger: .manual,
                                     startedAt: Self.ran, duration: 0, outcome: .skipped)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ScriptRunRecord.self, from: data)
        #expect(decoded.output == nil)
        #expect(decoded.log.isEmpty)
    }
}
