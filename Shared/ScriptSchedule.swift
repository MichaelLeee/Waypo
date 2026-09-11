import Foundation

/// When a script fires. Both forms share one type, so dropping either later
/// is a parser-only change.
enum ScriptSchedule: Hashable, Sendable {
    /// Fires every N seconds, measured from the last scheduled fire.
    case interval(seconds: Int)
    /// Fires at wall-clock times described by a five-field cron expression.
    case cron(CronExpression)

    /// Floor below which an interval would fire continuously.
    static let minimumIntervalSeconds = 10
    /// Ceiling that keeps an interval meaningful as a schedule.
    static let maximumIntervalSeconds = 30 * 24 * 60 * 60

    /// Parses `every 30s` / `every 5m` / `every 1h` / `every 1d`, or a
    /// five-field cron expression.
    static func parse(_ text: String) throws -> ScriptSchedule {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptScheduleError.empty }
        if trimmed.lowercased().hasPrefix(Self.intervalPrefix) {
            return .interval(seconds: try Self.parseInterval(trimmed))
        }
        return .cron(try CronExpression.parse(trimmed))
    }

    /// The first fire strictly after `date`, or nil when none is reachable.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let seconds):
            return date.addingTimeInterval(TimeInterval(seconds))
        case .cron(let expression):
            return expression.nextFireDate(after: date, calendar: calendar)
        }
    }

    private static let intervalPrefix = "every"

    private static func parseInterval(_ text: String) throws -> Int {
        let body = String(text.dropFirst(intervalPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let unit = body.last, let multiplier = unitMultiplier(unit) else {
            throw ScriptScheduleError.invalidInterval(text)
        }
        let digits = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, let amount = Int(digits), amount > 0 else {
            throw ScriptScheduleError.invalidInterval(text)
        }
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        guard !overflow,
              seconds >= minimumIntervalSeconds,
              seconds <= maximumIntervalSeconds
        else {
            throw ScriptScheduleError.invalidInterval(text)
        }
        return seconds
    }

    private static func unitMultiplier(_ unit: Character) -> Int? {
        switch unit {
        case "s", "S": return 1
        case "m", "M": return 60
        case "h", "H": return 3600
        case "d", "D": return 24 * 60 * 60
        default: return nil
        }
    }
}

extension ScriptSchedule: Codable {
    private enum Kind: String, Codable {
        case interval
        case cron
    }

    private enum CodingKeys: String, CodingKey {
        case kind, seconds, cron
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .interval:
            self = .interval(seconds: try container.decode(Int.self, forKey: .seconds))
        case .cron:
            self = .cron(try container.decode(CronExpression.self, forKey: .cron))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .cron(let expression):
            try container.encode(Kind.cron, forKey: .kind)
            try container.encode(expression, forKey: .cron)
        }
    }
}

/// A five-field cron expression: minute, hour, day of month, month, day of
/// week (0–7, both 0 and 7 meaning Sunday).
struct CronExpression: Hashable, Sendable {
    var minute: CronField
    var hour: CronField
    var dayOfMonth: CronField
    var month: CronField
    var dayOfWeek: CronField
    /// What the user typed, kept for display.
    var text: String

    /// Days `nextFireDate` will walk before giving up. A leap day is at most
    /// four years out, so this leaves a comfortable margin.
    static let dayScanLimit = 1500

    /// Rejects names, `L`, `W`, `#`, and any field count other than five.
    /// Supported per comma-separated item: `*`, `n`, `a-b`, `a/n`, `*/n`,
    /// `a-b/n`. Ranges must not wrap (`a <= b`).
    static func parse(_ text: String) throws -> CronExpression {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ScriptScheduleError.fieldCount(fields.count) }
        return CronExpression(
            minute: try parseField(fields[0], name: "minute", bounds: 0...59),
            hour: try parseField(fields[1], name: "hour", bounds: 0...23),
            dayOfMonth: try parseField(fields[2], name: "day of month", bounds: 1...31),
            month: try parseField(fields[3], name: "month", bounds: 1...12),
            dayOfWeek: try parseField(fields[4], name: "day of week", bounds: 0...7,
                                      normalizeSunday: true),
            text: trimmed
        )
    }

    /// Whether the day part of the expression admits `day`.
    ///
    /// Vixie cron's rule: when both day-of-month and day-of-week are
    /// restricted, either matching is enough; when only one is, that one
    /// decides.
    func matchesDay(_ day: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.day, .month, .weekday], from: day)
        guard let dayOfMonthValue = components.day,
              let monthValue = components.month,
              let weekday = components.weekday
        else { return false }
        guard month.matches(monthValue) else { return false }

        // Calendar weekdays start at 1 (Sunday); cron's start at 0.
        let dayOfWeekMatches = dayOfWeek.matches(weekday - 1)
        let dayOfMonthMatches = dayOfMonth.matches(dayOfMonthValue)

        if dayOfMonth.isWildcard && dayOfWeek.isWildcard { return true }
        if dayOfMonth.isWildcard { return dayOfWeekMatches }
        if dayOfWeek.isWildcard { return dayOfMonthMatches }
        return dayOfMonthMatches || dayOfWeekMatches
    }

    /// The first allowed wall-clock minute strictly after `date`, scanning
    /// forward a day at a time rather than minute by minute.
    func nextFireDate(after date: Date, calendar: Calendar) -> Date? {
        guard let earliest = Self.firstMinute(after: date, calendar: calendar),
              var day = calendar.dateInterval(of: .day, for: earliest)?.start
        else { return nil }

        for _ in 0..<Self.dayScanLimit {
            if matchesDay(day, calendar: calendar),
               let fire = firstAllowedMinute(on: day, calendar: calendar, notBefore: earliest) {
                return fire
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                return nil
            }
            day = next
        }
        return nil
    }

    private static func firstMinute(after date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let floored = calendar.date(from: components) else { return nil }
        guard floored <= date else { return floored }
        return calendar.date(byAdding: .minute, value: 1, to: floored)
    }

    private func firstAllowedMinute(on day: Date, calendar: Calendar,
                                    notBefore floor: Date) -> Date? {
        guard let startOfDay = calendar.dateInterval(of: .day, for: day)?.start else { return nil }
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        for hourValue in hour.values {
            for minuteValue in minute.values {
                var components = dayComponents
                components.hour = hourValue
                components.minute = minuteValue
                components.second = 0
                guard let candidate = calendar.date(from: components), candidate >= floor else {
                    continue
                }
                // A wall-clock time that does not exist (the spring-forward
                // gap) normalises to a different hour; skip it.
                let check = calendar.dateComponents([.hour, .minute], from: candidate)
                guard check.hour == hourValue, check.minute == minuteValue else { continue }
                return candidate
            }
        }
        return nil
    }

    private static func parseField(_ raw: String, name: String, bounds: ClosedRange<Int>,
                                   normalizeSunday: Bool = false) throws -> CronField {
        guard !raw.isEmpty else { throw ScriptScheduleError.invalidValue(name, raw) }
        guard raw != "*" else {
            return CronField(values: Array(bounds), isWildcard: true)
        }

        var collected: Set<Int> = []
        for item in raw.split(separator: ",", omittingEmptySubsequences: false) {
            try collect(String(item), name: name, bounds: bounds, into: &collected)
        }
        guard !collected.isEmpty else { throw ScriptScheduleError.empty }

        let normalized = normalizeSunday ? Set(collected.map { $0 == 7 ? 0 : $0 }) : collected
        return CronField(values: normalized.sorted(), isWildcard: false)
    }

    private static func collect(_ item: String, name: String, bounds: ClosedRange<Int>,
                                into collected: inout Set<Int>) throws {
        guard !item.isEmpty else { throw ScriptScheduleError.invalidValue(name, item) }

        let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, !parts[0].isEmpty else {
            throw ScriptScheduleError.invalidStep(name, item)
        }

        var step = 1
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed >= 1,
                  parsed <= bounds.upperBound - bounds.lowerBound + 1
            else {
                throw ScriptScheduleError.invalidStep(name, parts[1])
            }
            step = parsed
        }
        let hasStep = parts.count == 2

        let base = parts[0]
        let lower: Int
        let upper: Int
        if base == "*" {
            lower = bounds.lowerBound
            upper = bounds.upperBound
        } else if base.contains("-") {
            let ends = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard ends.count == 2,
                  let low = Int(ends[0]), let high = Int(ends[1]),
                  bounds.contains(low), bounds.contains(high), low <= high
            else {
                throw ScriptScheduleError.invalidRange(name, base)
            }
            lower = low
            upper = high
        } else if let value = Int(base), bounds.contains(value) {
            lower = value
            // `a/n` means "from a to the end of the field, every n".
            upper = hasStep ? bounds.upperBound : value
        } else {
            throw ScriptScheduleError.invalidValue(name, base)
        }

        var value = lower
        while value <= upper {
            collected.insert(value)
            value += step
        }
    }
}

/// One parsed cron field.
struct CronField: Hashable, Sendable {
    /// Allowed values, ascending and unique.
    var values: [Int]
    /// True only for a bare `*`, which the day-of-month/day-of-week
    /// combination rule depends on.
    var isWildcard: Bool

    func matches(_ value: Int) -> Bool {
        values.contains(value)
    }
}

enum ScriptScheduleError: Error, Equatable, LocalizedError {
    case fieldCount(Int)
    case empty
    /// Field name, offending item.
    case invalidValue(String, String)
    case invalidStep(String, String)
    case invalidRange(String, String)
    case invalidInterval(String)

    var errorDescription: String? {
        switch self {
        case .fieldCount(let count):
            return "A schedule needs five fields (minute, hour, day of month, month, day of week); this one has \(count)."
        case .empty:
            return "The schedule is empty."
        case .invalidValue(let field, let item):
            return "“\(item)” is not a value the \(field) field accepts."
        case .invalidStep(let field, let item):
            return "“\(item)” is not a valid step for the \(field) field."
        case .invalidRange(let field, let item):
            return "“\(item)” is not a valid range for the \(field) field."
        case .invalidInterval(let text):
            return "“\(text)” is not a valid interval. Use a form like every 30m, between 10s and 30d."
        }
    }
}

enum ScriptScheduler {
    /// The enabled cron and interval scripts whose next fire has arrived.
    /// Measures from the last scheduled fire so a script that was missed
    /// while the app was suspended fires once, not once per missed interval.
    static func due(_ scripts: [Script], now: Date, calendar: Calendar = .current) -> [Script] {
        scripts.filter { script in
            guard script.isEnabled, let schedule = script.schedule else { return false }
            let anchor = script.lastScheduledFireAt ?? script.createdAt
            guard let next = schedule.nextFireDate(after: anchor, calendar: calendar) else {
                return false
            }
            return next <= now
        }
    }

    /// A short human description of a schedule, for the editor's summary line.
    static func nextFireDescription(_ schedule: ScriptSchedule) -> String {
        switch schedule {
        case .interval(let seconds):
            if seconds % 3600 == 0 {
                let hours = seconds / 3600
                return hours == 1 ? "Every hour" : "Every \(hours) hours"
            }
            if seconds % 60 == 0 {
                let minutes = seconds / 60
                return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
            }
            return "Every \(seconds) seconds"
        case .cron(let expression):
            return "Cron “\(expression.text)”"
        }
    }
}
