import Foundation

public enum WorkdayDates {
    public static func date(_ day: String, minutes: Int = 0, timezone: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, minutes >= 0 else { return nil }
        let calendar = Clock.calendar(timezone: timezone)
        guard let base = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            Clock.day(base, timezone: timezone) == day,
            let offset = calendar.date(byAdding: .day, value: minutes / 1440, to: base)
        else { return nil }
        return calendar.date(bySettingHour: minutes % 1440 / 60, minute: minutes % 60, second: 0, of: offset)
    }

    public static func checkout(_ date: Date, day: String, timezone: String, payload: EntryPayload) throws -> EntryPayload {
        let calendar = Clock.calendar(timezone: timezone)
        guard let start = self.date(day, timezone: timezone),
            let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw TracyError.server("Choose a valid working day.")
        }
        let selectedDay = Clock.day(date, timezone: timezone)
        guard selectedDay == day || selectedDay == Clock.day(next, timezone: timezone) else {
            throw TracyError.server("Checkout must be on the working day or the following day.")
        }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        if payload.sessions != nil {
            return try payload.sessionAction(checkOut: true,
                minute: time.hour! * 60 + time.minute! + (selectedDay != day ? 1440 : 0),
                projectId: payload.sessions?.last?.projectId)
        }
        var result = payload
        result.checkOut = String(format: "%02d:%02d", time.hour!, time.minute!)
        result.checkOutNextDay = selectedDay != day
        if let message = result.validationMessage { throw TracyError.server(message) }
        return result
    }
}

public struct WorkdayReminder: Equatable, Sendable {
    public enum Kind: String, Sendable { case automaticBreak, eightHours }
    public let kind: Kind
    public let day: String
    public let fireDate: Date

    public static func plan(entry: WorkEntry, timezone: String, now: Date) -> [Self] {
        guard !entry.isDayOff, entry.checkOut == nil,
            let start = entry.checkIn.flatMap(Clock.minutes),
            entry.payload.validationMessage == nil else { return [] }
        var result: [Self] = []
        func append(_ kind: Kind, minutes: Int) {
            if let date = WorkdayDates.date(entry.date, minutes: minutes, timezone: timezone), date > now {
                result.append(Self(kind: kind, day: entry.date, fireDate: date))
            }
        }
        if let sessions = entry.sessions, let last = sessions.last, last.end == nil {
            if last.breakMinutes == nil { append(.automaticBreak, minutes: last.start + 361) }
            let completed = sessions.dropLast().reduce(0) { $0 + $1.exact }
            let needed = max(0, 480 - completed)
            let deduction = last.breakMinutes ?? (needed > 360 ? 30 : 0)
            if needed > 0 { append(.eightHours, minutes: last.start + needed + deduction) }
            return result
        }
        if entry.breaks.isEmpty { append(.automaticBreak, minutes: start + 361) }
        let deduction = entry.breaks.isEmpty ? 30 : entry.breaks.reduce(0) { total, item in
            if item.mode == "duration" { return total + (item.durationMinutes ?? 0) }
            let from = Clock.minutes(item.start ?? "") ?? 0
            let to = Clock.minutes(item.end ?? "") ?? 0
            return total + to - from + (to < from ? 1440 : 0)
        }
        append(.eightHours, minutes: start + 480 + deduction)
        return result
    }
}

public struct VacationRange: Codable, Equatable, Sendable {
    public let start: String
    public let end: String

    public init(start: String, end: String) throws {
        guard let first = WorkdayDates.date(start, timezone: "UTC"),
            let last = WorkdayDates.date(end, timezone: "UTC"),
            last >= first, last.timeIntervalSince(first) / 86400 < 366 else {
            throw TracyError.server("Choose an ordered vacation range of at most 366 days.")
        }
        self.start = start
        self.end = end
    }
}
