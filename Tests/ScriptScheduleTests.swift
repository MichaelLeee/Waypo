import Foundation
import Testing

/// A fixed UTC calendar so every expectation is deterministic.
private enum UTC {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    static func label(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The next fire rendered as `yyyy-MM-dd HH:mm`, or an error description.
    static func next(_ text: String, after date: Date) -> String {
        do {
            let schedule = try ScriptSchedule.parse(text)
            guard let fire = schedule.nextFireDate(after: date, calendar: calendar) else {
                return "no next fire"
            }
            return label(fire)
        } catch {
            return "error: \(error)"
        }
    }
}

@Suite
struct ScriptScheduleParsingTests {
    @Test
    func intervalFormsParse() throws {
        #expect(try ScriptSchedule.parse("every 30s") == .interval(seconds: 30))
        #expect(try ScriptSchedule.parse("every 5m") == .interval(seconds: 300))
        #expect(try ScriptSchedule.parse("every 1h") == .interval(seconds: 3600))
        #expect(try ScriptSchedule.parse("EVERY 10M") == .interval(seconds: 600))
        #expect(try ScriptSchedule.parse("  every 2 h  ") == .interval(seconds: 7200))
        #expect(try ScriptSchedule.parse("every 30d") == .interval(seconds: 2592000))
    }

    @Test
    func intervalRejectsOutOfRangeAndMalformed() {
        for text in ["every 5s", "every 0m", "every m", "every 31d", "every 5x",
                     "every", "every ", "every 99999999999h"] {
            #expect(throws: ScriptScheduleError.self) {
                try ScriptSchedule.parse(text)
            }
        }
    }

    @Test
    func emptyScheduleIsRejected() {
        #expect(throws: ScriptScheduleError.empty) {
            try ScriptSchedule.parse("   ")
        }
    }

    @Test
    func cronFieldsParse() throws {
        let wildcard = try CronExpression.parse("* * * * *")
        #expect(wildcard.minute.isWildcard)
        #expect(wildcard.minute.values.count == 60)
        #expect(wildcard.dayOfWeek.isWildcard)
        #expect(wildcard.dayOfWeek.values == Array(0...6))
        #expect(wildcard.text == "* * * * *")

        let stepped = try CronExpression.parse("*/5 * * * *")
        #expect(!stepped.minute.isWildcard)
        #expect(stepped.minute.values == Array(stride(from: 0, through: 55, by: 5)))

        let shifted = try CronExpression.parse("5/15 * * * *")
        #expect(shifted.minute.values == [5, 20, 35, 50])

        let ranged = try CronExpression.parse("30 9-17 * * 1-5")
        #expect(ranged.minute.values == [30])
        #expect(ranged.hour.values == Array(9...17))
        #expect(ranged.dayOfWeek.values == [1, 2, 3, 4, 5])

        let steppedRange = try CronExpression.parse("0 0-23/6 * * *")
        #expect(steppedRange.hour.values == [0, 6, 12, 18])

        let listed = try CronExpression.parse("0 0 1,15 * *")
        #expect(listed.dayOfMonth.values == [1, 15])

        // Both 0 and 7 mean Sunday.
        let sundayAsSeven = try CronExpression.parse("0 0 * * 7")
        let sundayAsZero = try CronExpression.parse("0 0 * * 0")
        #expect(sundayAsSeven.dayOfWeek.values == [0])
        #expect(sundayAsZero.dayOfWeek.values == [0])
    }

    @Test
    func cronRejectsWhatItDoesNotSupport() {
        let rejected = [
            "", "* * * *", "* * * * * *", "* * * * * * *",
            "60 * * * *", "* 24 * * *", "* * 0 * *", "* * 32 * *",
            "* * * 0 *", "* * * 13 *", "* * * * 8",
            "5-1 * * * *", "*/0 * * * *", "*/61 * * * *", "*/100 * * * *",
            "a * * * *", "1,,2 * * * *", "* * * * MON", "* * L * *",
            "* * * * 1#2", "* * * * 1W", "1- * * * *", "-5 * * * *",
        ]
        for text in rejected {
            #expect(throws: ScriptScheduleError.self) {
                try CronExpression.parse(text)
            }
        }
    }

    @Test
    func emptyTextReportsNoFields() {
        #expect(throws: ScriptScheduleError.fieldCount(0)) {
            try CronExpression.parse("")
        }
    }

    @Test
    func errorDescriptionsAreHumanReadable() {
        #expect(ScriptScheduleError.empty.errorDescription?.isEmpty == false)
        #expect(ScriptScheduleError.fieldCount(3).errorDescription?.contains("3") == true)
        #expect(ScriptScheduleError.invalidValue("hour", "24")
            .errorDescription?.contains("24") == true)
        #expect(ScriptScheduleError.invalidStep("minute", "0")
            .errorDescription?.contains("0") == true)
        #expect(ScriptScheduleError.invalidRange("hour", "5-1")
            .errorDescription?.contains("5-1") == true)
        #expect(ScriptScheduleError.invalidInterval("every 1s")
            .errorDescription?.contains("every 1s") == true)
    }
}

@Suite
struct CronNextFireTests {
    @Test
    func advancesWithinTheHour() {
        #expect(UTC.next("*/15 * * * *", after: UTC.date(2026, 1, 1, 0, 7)) == "2026-01-01 00:15")
        #expect(UTC.next("30 * * * *", after: UTC.date(2026, 1, 1, 0, 7)) == "2026-01-01 00:30")
        #expect(UTC.next("5 * * * *", after: UTC.date(2026, 1, 1, 0, 30)) == "2026-01-01 01:05")
    }

    @Test
    func firesStrictlyAfterTheGivenInstant() {
        #expect(UTC.next("0 3 * * *", after: UTC.date(2026, 1, 1, 1, 0)) == "2026-01-01 03:00")
        // Exactly on the fire minute still moves to the next day.
        #expect(UTC.next("0 3 * * *", after: UTC.date(2026, 1, 1, 3, 0)) == "2026-01-02 03:00")
        #expect(UTC.next("0 3 * * *", after: UTC.date(2026, 1, 1, 3, 0, 30)) == "2026-01-02 03:00")
        #expect(UTC.next("0 3 * * *", after: UTC.date(2026, 1, 1, 3, 30)) == "2026-01-02 03:00")
    }

    @Test
    func crossesDaysAndMonths() {
        #expect(UTC.next("0 0 * * *", after: UTC.date(2026, 1, 1, 5, 0)) == "2026-01-02 00:00")
        #expect(UTC.next("0 0 1 * *", after: UTC.date(2026, 1, 15)) == "2026-02-01 00:00")
        #expect(UTC.next("0 0 1 1 *", after: UTC.date(2026, 6, 1)) == "2027-01-01 00:00")
    }

    @Test
    func reachesALeapDay() {
        #expect(UTC.next("0 0 29 2 *", after: UTC.date(2026, 3, 1)) == "2028-02-29 00:00")
    }

    @Test
    func weekdayRestrictionPicksTheRightDay() {
        // 2026-01-01 is a Thursday.
        #expect(UTC.next("0 12 * * 1", after: UTC.date(2026, 1, 1)) == "2026-01-05 12:00")
        #expect(UTC.next("0 12 * * 0", after: UTC.date(2026, 1, 1)) == "2026-01-04 12:00")
    }

    @Test
    func bothRestrictedDaysMatchEitherWay() {
        // Day 1 or a Monday, whichever comes first.
        #expect(UTC.next("0 0 1 * 1", after: UTC.date(2026, 1, 2)) == "2026-01-05 00:00")
        // Only day-of-month is restricted, so it decides alone.
        #expect(UTC.next("0 0 1 * *", after: UTC.date(2026, 1, 2)) == "2026-02-01 00:00")
        // Only day-of-week is restricted, likewise.
        #expect(UTC.next("0 0 * * 1", after: UTC.date(2026, 1, 2)) == "2026-01-05 00:00")
    }

    @Test
    func monthRestrictionIsRespected() {
        #expect(UTC.next("0 0 * 12 *", after: UTC.date(2026, 1, 1)) == "2026-12-01 00:00")
        #expect(UTC.next("0 0 * * *", after: UTC.date(2026, 1, 1, 0, 1)) == "2026-01-02 00:00")
    }

    @Test
    func matchesDayAppliesTheOrRule() throws {
        let calendar = UTC.calendar
        let expression = try CronExpression.parse("0 0 1 * 1")
        // 2026-01-01 is a Thursday and the first, so day-of-month matches.
        #expect(expression.matchesDay(UTC.date(2026, 1, 1), calendar: calendar))
        // 2026-01-05 is a Monday but not the first, so day-of-week matches.
        #expect(expression.matchesDay(UTC.date(2026, 1, 5), calendar: calendar))
        // 2026-01-06 is neither.
        #expect(!expression.matchesDay(UTC.date(2026, 1, 6), calendar: calendar))
        // February is a wildcard here, so the first matches on day-of-month.
        #expect(expression.matchesDay(UTC.date(2026, 2, 1), calendar: calendar))
    }

    @Test
    func skippedWallClockTimeMovesToTheNextDay() throws {
        // 2026-03-08 is the spring-forward day in New York: 02:30 does not
        // exist, so the fire lands the following day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let expression = try CronExpression.parse("30 2 * * *")
        let fire = expression.nextFireDate(after: UTC.date(2026, 3, 8, 0, 0), calendar: calendar)
        let components = try #require(fire.map {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        })
        #expect(components.day == 9)
        #expect(components.hour == 2)
        #expect(components.minute == 30)
    }
}

@Suite
struct ScriptSchedulerTests {
    private static func script(kind: ScriptKind = .cron, schedule: ScriptSchedule?,
                               enabled: Bool = true, created: Date, lastRun: Date? = nil,
                               lastFire: Date? = nil) -> Script {
        Script(name: "S", kind: kind, schedule: schedule, isEnabled: enabled,
               createdAt: created, lastRunAt: lastRun, lastScheduledFireAt: lastFire)
    }

    @Test
    func intervalScheduleFiresOnceItsIntervalHasPassed() {
        let start = UTC.date(2026, 1, 1, 0, 0)
        let script = Self.script(schedule: .interval(seconds: 60), created: start)

        let early = ScriptScheduler.due([script], now: UTC.date(2026, 1, 1, 0, 0, 59),
                                        calendar: UTC.calendar)
        let late = ScriptScheduler.due([script], now: UTC.date(2026, 1, 1, 0, 1),
                                       calendar: UTC.calendar)
        #expect(early.isEmpty)
        #expect(late.count == 1)
    }

    @Test
    func cronScheduleFiresOnceThenWaitsForTheNextSlot() throws {
        let start = UTC.date(2026, 1, 1, 0, 0)
        let schedule = ScriptSchedule.cron(try CronExpression.parse("*/5 * * * *"))

        let waiting = Self.script(schedule: schedule, created: start)
        let tooSoon = ScriptScheduler.due([waiting], now: UTC.date(2026, 1, 1, 0, 3),
                                          calendar: UTC.calendar)
        let onTime = ScriptScheduler.due([waiting], now: UTC.date(2026, 1, 1, 0, 5),
                                         calendar: UTC.calendar)
        #expect(tooSoon.isEmpty)
        #expect(onTime.count == 1)

        // Once the anchor moves, the same instant is no longer due.
        let fired = Self.script(schedule: schedule, created: start,
                                lastFire: UTC.date(2026, 1, 1, 0, 5))
        let again = ScriptScheduler.due([fired], now: UTC.date(2026, 1, 1, 0, 5),
                                        calendar: UTC.calendar)
        #expect(again.isEmpty)
    }

    @Test
    func aLongGapFiresOnceNotOncePerInterval() {
        let script = Self.script(schedule: .interval(seconds: 60), created: UTC.date(2025, 1, 1))
        let due = ScriptScheduler.due([script], now: UTC.date(2026, 1, 1),
                                      calendar: UTC.calendar)
        #expect(due.count == 1)
    }

    @Test
    func disabledAndUnscheduledScriptsNeverFire() {
        let start = UTC.date(2026, 1, 1)
        let now = UTC.date(2026, 6, 1)
        let disabled = Self.script(schedule: .interval(seconds: 60), enabled: false,
                                   created: start)
        let unscheduled = Self.script(schedule: nil, created: start)
        let eventOnly = Self.script(kind: .event, schedule: nil, created: start)
        let due = ScriptScheduler.due([disabled, unscheduled, eventOnly], now: now,
                                      calendar: UTC.calendar)
        #expect(due.isEmpty)
    }

    @Test
    func manualRunsDoNotMoveTheScheduleAnchor() throws {
        let schedule = ScriptSchedule.cron(try CronExpression.parse("*/5 * * * *"))
        // A manual run happened a moment ago; the schedule anchor is still
        // creation, so the script is due.
        let script = Self.script(schedule: schedule, created: UTC.date(2026, 1, 1, 0, 0),
                                 lastRun: UTC.date(2026, 1, 1, 0, 5))
        let due = ScriptScheduler.due([script], now: UTC.date(2026, 1, 1, 0, 5),
                                      calendar: UTC.calendar)
        #expect(due.count == 1)
    }

    @Test
    func descriptionsReadNaturally() throws {
        #expect(ScriptScheduler.nextFireDescription(.interval(seconds: 30)) == "Every 30 seconds")
        #expect(ScriptScheduler.nextFireDescription(.interval(seconds: 60)) == "Every minute")
        #expect(ScriptScheduler.nextFireDescription(.interval(seconds: 300)) == "Every 5 minutes")
        #expect(ScriptScheduler.nextFireDescription(.interval(seconds: 3600)) == "Every hour")
        #expect(ScriptScheduler.nextFireDescription(.interval(seconds: 7200)) == "Every 2 hours")
        let cron = try CronExpression.parse("0 3 * * *")
        #expect(ScriptScheduler.nextFireDescription(.cron(cron)).contains("0 3 * * *"))
    }

    @Test
    func scheduleRoundTripsThroughCodable() throws {
        let cron = ScriptSchedule.cron(try CronExpression.parse("30 3 * * 1-5"))
        for schedule: ScriptSchedule in [.interval(seconds: 90), cron] {
            let data = try JSONEncoder().encode(schedule)
            let decoded = try JSONDecoder().decode(ScriptSchedule.self, from: data)
            #expect(decoded == schedule)
        }
    }
}
