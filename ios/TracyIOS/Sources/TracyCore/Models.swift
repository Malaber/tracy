import Foundation

public struct WorkBreak: Codable, Equatable, Sendable {
    public var automatic: Bool?
    public var mode: String
    public var durationMinutes: Int?
    public var start: String?
    public var end: String?

    public init(
        automatic: Bool = false, mode: String = "duration", durationMinutes: Int? = 30, start: String? = nil, end: String? = nil
    ) {
        self.automatic = automatic
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
    public var projectAllocations: [ProjectAllocation]?
    public var defaultProjectId: Int?
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
            notes: notes, projectAllocations: projectAllocations, defaultProjectId: defaultProjectId)
    }
}

public struct EntryPayload: Codable, Equatable, Sendable {
    public var checkIn: String?
    public var checkOut: String?
    public var checkOutNextDay: Bool
    public var breaks: [WorkBreak]
    public var projectAllocations: [ProjectAllocation]?
    public var defaultProjectId: Int?
    public var notes: String

    public init(
        checkIn: String? = nil, checkOut: String? = nil, checkOutNextDay: Bool = false,
        breaks: [WorkBreak] = [], notes: String = "", projectAllocations: [ProjectAllocation]? = nil, defaultProjectId: Int? = nil
    ) {
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.checkOutNextDay = checkOutNextDay
        self.breaks = breaks
        self.notes = notes
        self.projectAllocations = projectAllocations
        self.defaultProjectId = defaultProjectId
    }

    enum CodingKeys: String, CodingKey {
        case checkIn, checkOut, checkOutNextDay, breaks, notes, projectAllocations, defaultProjectId
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(checkIn, forKey: .checkIn)
        try values.encode(checkOut, forKey: .checkOut)
        try values.encode(checkOutNextDay, forKey: .checkOutNextDay)
        try values.encode(breaks, forKey: .breaks)
        try values.encode(notes, forKey: .notes)
        try values.encodeIfPresent(projectAllocations, forKey: .projectAllocations)
        try values.encode(defaultProjectId, forKey: .defaultProjectId)
    }

    public var exactMinutes: Int? {
        guard validationMessage == nil, let start = checkIn.flatMap(Clock.minutes),
              let end = checkOut.flatMap(Clock.minutes) else { return nil }
        let deduction = breaks.reduce(0) { sum, item in
            if item.mode == "duration" { return sum + (item.durationMinutes ?? 0) }
            let from = Clock.minutes(item.start ?? "") ?? 0
            let to = Clock.minutes(item.end ?? "") ?? 0
            return sum + to - from + (to < from ? 1440 : 0)
        }
        return end + (checkOutNextDay ? 1440 : 0) - start - deduction
    }

    public func bookingValidation(rounding: Int) -> String? {
        if let error = validationMessage { return error }
        if let exact = exactMinutes {
            let increment = max(1, rounding)
            if (projectAllocations ?? []).reduce(0, { $0 + $1.minutes }) > (exact + increment - 1) / increment * increment {
                return "Project bookings exceed this day's billable time."
            }
        }
        return nil
    }

    public var validationMessage: String? {
        if let allocations = projectAllocations,
            allocations.count > 50 || allocations.contains(where: { $0.projectId <= 0 || $0.minutes <= 0 || $0.minutes > 2880 }) {
            return "Choose a project and a positive duration for every booking (up to 50)."
        }
        guard notes.count <= 2000 else { return "Keep notes to 2,000 characters." }
        guard breaks.count <= 20 else { return "Use at most 20 breaks." }
        guard let checkIn else {
            return checkOut != nil || !breaks.isEmpty ? "Add a check-in first." : nil
        }
        guard let start = Clock.minutes(checkIn) else { return "Choose a valid check-in time." }
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
        guard let checkOut else { return nil }
        guard let end = Clock.minutes(checkOut) else { return "Choose a valid check-out time." }
        let span = end + (checkOutNextDay ? 1440 : 0) - start
        guard span > 0 else {
            return "Check-out must be after check-in. For overnight work, turn on Next day."
        }
        return total >= span ? "Breaks must be shorter than the working day." : nil
    }

    /// Reopen the same day's entry, optionally retaining time away as a break.
    public func reopened(resumeAt: String? = nil) throws -> Self {
        guard checkIn != nil, let checkout = checkOut, !checkOutNextDay,
            validationMessage == nil else {
            throw TracyError.server("Only a completed same-day entry can be reopened.")
        }
        var result = self
        if let resumeAt {
            guard let end = Clock.minutes(checkout), let resume = Clock.minutes(resumeAt),
                resume >= end else {
                throw TracyError.server("Resume time must be at or after checkout.")
            }
            if resume > end {
                result.breaks.append(WorkBreak(mode: "range", durationMinutes: nil,
                                              start: checkout, end: resumeAt))
            }
        }
        result.checkOut = nil
        result.checkOutNextDay = false
        if let message = result.validationMessage { throw TracyError.server(message) }
        return result
    }

    public var removingPrematureAutomaticBreaks: Self {
        guard let start = checkIn.flatMap(Clock.minutes), let end = checkOut.flatMap(Clock.minutes),
              end + (checkOutNextDay ? 1440 : 0) - start <= 360 else { return self }
        var result = self
        result.breaks.removeAll { $0.automatic == true }
        return result
    }

    public func applyingDefaultBreak(previous: EntryPayload) -> Self {
        let cleaned = removingPrematureAutomaticBreaks
        if cleaned != self { return cleaned.applyingDefaultBreak(previous: previous) }
        guard previous.checkIn == nil || previous.checkOut == nil,
            breaks.isEmpty, let start = checkIn.flatMap(Clock.minutes),
            let end = checkOut.flatMap(Clock.minutes),
            end + (checkOutNextDay ? 1440 : 0) - start > 360
        else { return self }
        var result = self
        result.breaks = [WorkBreak(automatic: true, durationMinutes: 30)]
        return result
    }
}

public struct SignOffEstimate: Equatable, Sendable {
    public let exactMinutes: Int
    public let billableMinutes: Int
    public let breakMinutes: Int
    public var progress: Double { min(1, max(0, Double(exactMinutes) / 480)) }

    public static func project(_ entry: WorkEntry, now: Date, timezone: String, rounding: Int = 15) -> Self? {
        guard entry.date == Clock.day(now, timezone: timezone), entry.checkOut == nil,
            let start = entry.checkIn.flatMap(Clock.minutes) else { return nil }
        let time = Clock.calendar(timezone: timezone).dateComponents([.hour, .minute], from: now)
        let end = time.hour! * 60 + time.minute!
        guard end >= start else { return nil }
        if end == start { return Self(exactMinutes: 0, billableMinutes: 0, breakMinutes: 0) }
        var payload = entry.payload
        payload.checkOut = String(format: "%02d:%02d", time.hour!, time.minute!)
        payload.checkOutNextDay = false
        payload = payload.applyingDefaultBreak(previous: entry.payload)
        guard payload.validationMessage == nil else { return nil }
        let breaks = payload.breaks.reduce(0) { total, item in
            if item.mode == "duration" { return total + (item.durationMinutes ?? 0) }
            let from = Clock.minutes(item.start!)!
            let to = Clock.minutes(item.end!)!
            return total + to - from + (to < from ? 1440 : 0)
        }
        let exact = end - start - breaks
        let increment = max(1, rounding)
        return Self(exactMinutes: exact, billableMinutes: (exact + increment - 1) / increment * increment,
                    breakMinutes: breaks)
    }
}

public struct WorkPreferences: Decodable, Sendable {
    public let roundingMinutes: Int
}

public struct DaySummary: Codable, Identifiable, Sendable {
    public let date: String
    public let weekday: String
    public let isWeekend: Bool
    public let holiday: String?
    public let isDayOff: Bool
    public let isWorkday: Bool
    public let expectedMinutes: Int
    public var exactMinutes: Int
    public var billableMinutes: Int
    public var balanceMinutes: Int
    public let status: String
    public let notes: String
    public var id: String { date }

    public func needsAttention(today: String) -> Bool {
        date < today
            && (status == "in_progress"
                || (expectedMinutes > 0 && (status != "complete" || billableMinutes < expectedMinutes)))
    }

    public func label(today: String) -> String {
        if status == "in_progress" { return date < today ? "Check-out missing" : "In progress" }
        if status == "complete" {
            return date < today && billableMinutes < expectedMinutes
                ? "Below target by \(Clock.duration(expectedMinutes - billableMinutes))" : "Entered"
        }
        if isDayOff { return "Day off" }
        if let holiday { return holiday }
        if isWeekend { return "Weekend" }
        return needsAttention(today: today) ? "Entry missing" : "Not entered"
    }
}

public struct Statistics: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public var exactMinutes: Int
        public var billableMinutes: Int
        public let targetMinutes: Int
        public var balanceMinutes: Int
        public let completedDays: Int
    }
    public var projectTotals: [ProjectAllocation]?
    public let start: String
    public let end: String
    public var summary: Summary
    public var days: [DaySummary]
}

extension Statistics {
    public func projecting(_ estimate: SignOffEstimate?, date: String) -> Self {
        guard let estimate, let index = days.firstIndex(where: { $0.date == date }) else { return self }
        var result = self
        let exactDelta = estimate.exactMinutes - days[index].exactMinutes
        let billableDelta = estimate.billableMinutes - days[index].billableMinutes
        result.days[index].exactMinutes = estimate.exactMinutes
        result.days[index].billableMinutes = estimate.billableMinutes
        result.days[index].balanceMinutes += billableDelta
        result.summary.exactMinutes += exactDelta
        result.summary.billableMinutes += billableDelta
        result.summary.balanceMinutes += billableDelta
        return result
    }
}

public struct ServerMeta: Decodable, Sendable {
    public let projectBookings: Bool?
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
