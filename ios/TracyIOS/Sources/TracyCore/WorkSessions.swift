import Foundation

public struct WorkSession: Codable, Equatable, Sendable {
    public var projectId: Int?
    public var start: Int
    public var end: Int?
    public var breakMinutes: Int?

    public init(projectId: Int?, start: Int, end: Int? = nil, breakMinutes: Int? = nil) {
        self.projectId = projectId; self.start = start; self.end = end; self.breakMinutes = breakMinutes
    }
    public var deduction: Int { breakMinutes ?? ((end ?? start) - start > 360 ? 30 : 0) }
    public var exact: Int { max(0, (end ?? start) - start - deduction) }
    public static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute % 1440 / 60, minute % 60)
    }
}

extension EntryPayload {
    public var sessionValidation: String? {
        guard let sessions else { return nil }
        if sessions.count > 50 { return "Use at most 50 sessions." }
        var previousEnd = 0
        for (index, session) in sessions.enumerated() {
            if session.start < previousEnd || !(0..<2880).contains(session.start)
                || (session.end == nil && index != sessions.count - 1) {
                return "Sessions must be ordered without overlaps; only the last may be open."
            }
            if let id = session.projectId, id <= 0 { return "Choose a valid project." }
            if let deduction = session.breakMinutes, !(0...1440).contains(deduction) { return "Choose valid break minutes." }
            if let end = session.end {
                if end > 2880 || end <= session.start || session.deduction >= end - session.start {
                    return "Checkout must follow check-in and breaks must be shorter than the session."
                }
                previousEnd = end
            }
        }
        return nil
    }

    public var normalizedSessions: Self {
        guard let sessions else { return self }
        var result = self
        result.checkIn = sessions.first.map { WorkSession.clock($0.start) }
        result.checkOut = sessions.last?.end.map(WorkSession.clock)
        result.checkOutNextDay = (sessions.last?.end ?? 0) >= 1440
        result.breaks = []
        result.projectAllocations = []
        return result
    }

    public func sessionAction(checkOut: Bool, minute: Int, projectId: Int?) throws -> Self {
        var result = self
        var items = sessions ?? []
        if sessions == nil, let start = checkIn.flatMap(Clock.minutes) {
            guard (projectAllocations ?? []).isEmpty else {
                throw TracyError.server("This day has manual project bookings. Keep editing it in the day form; start timed sessions on a new day.")
            }
            let deduction = breaks.reduce(0) { total, item in
                if item.mode == "duration" { return total + (item.durationMinutes ?? 0) }
                let start = Clock.minutes(item.start ?? "") ?? 0
                let end = Clock.minutes(item.end ?? "") ?? 0
                return total + end - start + (end < start ? 1440 : 0)
            }
            items = [WorkSession(projectId: defaultProjectId, start: start,
                                 end: checkOutTime, breakMinutes: !breaks.isEmpty && breaks.allSatisfy { $0.automatic == true } ? nil : (deduction > 0 || checkOut != nil ? deduction : nil))]
        }
        if checkOut {
            guard let last = items.last, last.end == nil else { throw TracyError.server("Check in before checking out.") }
            items[items.count - 1].end = minute
            items[items.count - 1].projectId = projectId
        } else {
            guard items.last?.end != nil || items.isEmpty else { throw TracyError.server("Check out of the current session first.") }
            items.append(WorkSession(projectId: projectId, start: minute))
        }
        result.sessions = items
        if let error = result.sessionValidation { throw TracyError.server(error) }
        return result.normalizedSessions
    }

    private var checkOutTime: Int? { checkOut.flatMap(Clock.minutes).map { $0 + (checkOutNextDay ? 1440 : 0) } }
}
