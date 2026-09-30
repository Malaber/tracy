import Foundation

public struct WorkBreak: Codable, Equatable, Sendable {
    public var mode: String
    public var durationMinutes: Int?
    public var start: String?
    public var end: String?

    public init(
        mode: String = "duration", durationMinutes: Int? = 30, start: String? = nil, end: String? = nil
    ) {
        self.mode = mode
        self.durationMinutes = durationMinutes
        self.start = start
        self.end = end
    }
}

public struct WorkEntry: Codable, Equatable, Identifiable, Sendable {
    public var date: String
    public var saved: Bool
    public var revision: String
    public var clientMutationId: String?
    public var isDayOff: Bool
    public var checkIn: String?
    public var checkOut: String?
    public var checkOutNextDay: Bool
    public var breaks: [WorkBreak]
    public var breakMinutes: Int
    public var exactMinutes: Int?
    public var billableMinutes: Int?
    public var status: String
    public var notes: String
    public var id: String { date }

    public static func empty(date: String) -> Self {
        Self(
            date: date, saved: false, revision: "missing", clientMutationId: nil, isDayOff: false,
            checkIn: nil, checkOut: nil,
            checkOutNextDay: false, breaks: [], breakMinutes: 0, exactMinutes: nil,
            billableMinutes: nil, status: "empty", notes: "")
    }

    public var payload: EntryPayload {
        EntryPayload(
            checkIn: checkIn, checkOut: checkOut, checkOutNextDay: checkOutNextDay, breaks: breaks,
            notes: notes)
    }
}

public struct EntryPayload: Codable, Equatable, Sendable {
    public var checkIn: String?
    public var checkOut: String?
    public var checkOutNextDay: Bool
    public var breaks: [WorkBreak]
    public var notes: String

    public init(
        checkIn: String? = nil, checkOut: String? = nil, checkOutNextDay: Bool = false,
        breaks: [WorkBreak] = [], notes: String = ""
    ) {
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.checkOutNextDay = checkOutNextDay
        self.breaks = breaks
        self.notes = notes
    }

    public var validationMessage: String? {
        guard notes.count <= 2000 else { return "Keep notes to 2,000 characters." }
        guard breaks.count <= 20 else { return "Use at most 20 breaks." }
        guard let checkIn else {
            return checkOut != nil || !breaks.isEmpty ? "Add a check-in first." : nil
        }
        guard let start = Clock.minutes(checkIn) else { return "Choose a valid check-in time." }
        guard let checkOut else {
            return breaks.isEmpty ? nil : "Add a check-out before adding breaks."
        }
        guard let end = Clock.minutes(checkOut) else { return "Choose a valid check-out time." }
        let span = end + (checkOutNextDay ? 1440 : 0) - start
        guard span > 0 else {
            return "Check-out must be after check-in. For overnight work, turn on Next day."
        }
        var total = 0
        for item in breaks {
            if item.mode == "duration" {
                guard let minutes = item.durationMinutes, (1...1440).contains(minutes) else {
                    return "Break duration must be between 1 and 1,440 minutes."
                }
                total += minutes
            } else {
                guard let from = item.start.flatMap(Clock.minutes), let to = item.end.flatMap(Clock.minutes),
                    from != to
                else {
                    return "Choose different start and end times for each break."
                }
                total += to - from + (to < from ? 1440 : 0)
            }
        }
        return total >= span ? "Breaks must be shorter than the working day." : nil
    }

    public func applyingDefaultBreak(previous: EntryPayload) -> Self {
        guard previous.checkIn == nil || previous.checkOut == nil,
            breaks.isEmpty, let start = checkIn.flatMap(Clock.minutes),
            let end = checkOut.flatMap(Clock.minutes),
            end + (checkOutNextDay ? 1440 : 0) - start > 270
        else { return self }
        var result = self
        result.breaks = [WorkBreak(durationMinutes: 30)]
        return result
    }
}

public struct DaySummary: Codable, Identifiable, Sendable {
    public let date: String
    public let weekday: String
    public let isWeekend: Bool
    public let holiday: String?
    public let isDayOff: Bool
    public let isWorkday: Bool
    public let expectedMinutes: Int
    public let exactMinutes: Int
    public let billableMinutes: Int
    public let balanceMinutes: Int
    public let status: String
    public let notes: String
    public var id: String { date }

    public func needsAttention(today: String) -> Bool {
        date < today
            && (status == "in_progress"
                || (expectedMinutes > 0 && (status != "complete" || exactMinutes < expectedMinutes)))
    }

    public func label(today: String) -> String {
        if status == "in_progress" { return date < today ? "Check-out missing" : "In progress" }
        if status == "complete" {
            return date < today && exactMinutes < expectedMinutes
                ? "Below target by \(Clock.duration(expectedMinutes - exactMinutes))" : "Entered"
        }
        if isDayOff { return "Day off" }
        if let holiday { return holiday }
        if isWeekend { return "Weekend" }
        return needsAttention(today: today) ? "Entry missing" : "Not entered"
    }
}

public struct Statistics: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public let exactMinutes: Int
        public let billableMinutes: Int
        public let targetMinutes: Int
        public let balanceMinutes: Int
        public let completedDays: Int
    }
    public let start: String
    public let end: String
    public let summary: Summary
    public let days: [DaySummary]
}

public struct ServerMeta: Decodable, Sendable {
    public let timezone: String
}

public enum Clock {
    public static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
            (0...23).contains(hours), (0...59).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }

    public static func duration(_ minutes: Int) -> String {
        let magnitude = abs(minutes)
        return "\(minutes < 0 ? "−" : "")\(magnitude / 60)h \(magnitude % 60)m"
    }

    public static func calendar(timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    public static func day(_ date: Date, timezone: String) -> String {
        let components = calendar(timezone: timezone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    // A date-only key never passes through the device's timezone.
    public static func date(_ key: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key) ?? .distantPast
    }

    public static func title(_ key: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date(key))
    }
}
