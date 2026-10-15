import Foundation
import Testing
@testable import TracyCore

@Test func reminderTimesRespectBreaksAndTimezone() throws {
    var entry = WorkEntry.empty(date: "2026-10-15")
    entry.checkIn = "08:00"
    let early = WorkdayDates.date(entry.date, minutes: 480, timezone: "Europe/Berlin")!
    let plan = WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: early)
    #expect(plan.map(\.kind) == [.automaticBreak, .eightHours])
    #expect(plan[0].fireDate == WorkdayDates.date(entry.date, minutes: 841, timezone: "Europe/Berlin"))
    #expect(plan[1].fireDate == WorkdayDates.date(entry.date, minutes: 990, timezone: "Europe/Berlin"))
    #expect(WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: plan[0].fireDate).map(\.kind) == [.eightHours])
    entry.breaks = [.init(durationMinutes: 45), .init(mode: "range", durationMinutes: nil, start: "12:00", end: "12:15")]
    let explicit = WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: early)
    #expect(explicit.map(\.kind) == [.eightHours])
    #expect(explicit[0].fireDate == WorkdayDates.date(entry.date, minutes: 1020, timezone: "Europe/Berlin"))
    entry.checkOut = "17:00"
    #expect(WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: early).isEmpty)
    entry.checkOut = nil
    entry.isDayOff = true
    #expect(WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: early).isEmpty)
    entry.isDayOff = false
    entry.checkIn = nil
    #expect(WorkdayReminder.plan(entry: entry, timezone: "Europe/Berlin", now: early).isEmpty)
}

@Test func reminderCrossesMidnightAndReschedulesAfterResume() throws {
    var entry = WorkEntry.empty(date: "2026-10-15")
    entry.checkIn = "22:00"
    let now = WorkdayDates.date(entry.date, minutes: 1320, timezone: "UTC")!
    let plan = WorkdayReminder.plan(entry: entry, timezone: "UTC", now: now)
    #expect(plan[0].fireDate == WorkdayDates.date("2026-10-16", minutes: 241, timezone: "UTC"))
    #expect(plan[1].fireDate == WorkdayDates.date("2026-10-16", minutes: 390, timezone: "UTC"))
    entry.checkIn = "08:00"
    entry.breaks = [.init(durationMinutes: 30), .init(mode: "range", durationMinutes: nil, start: "15:00", end: "16:00")]
    let resumed = WorkdayReminder.plan(entry: entry, timezone: "UTC",
                                      now: WorkdayDates.date(entry.date, minutes: 960, timezone: "UTC")!)
    #expect(resumed.count == 1)
    #expect(resumed[0].fireDate == WorkdayDates.date(entry.date, minutes: 1050, timezone: "UTC"))
}

@Test func checkoutCorrectionUsesOriginalDayAndPreservesDraft() throws {
    let draft = EntryPayload(checkIn: "22:00", breaks: [.init(durationMinutes: 30)], notes: "Keep notes")
    let corrected = try WorkdayDates.checkout(
        WorkdayDates.date("2026-10-16", minutes: 360, timezone: "Europe/Berlin")!,
        day: "2026-10-15", timezone: "Europe/Berlin", payload: draft)
    #expect(corrected.checkOut == "06:00" && corrected.checkOutNextDay)
    #expect(corrected.notes == draft.notes && corrected.breaks == draft.breaks)
    #expect(throws: TracyError.self) {
        try WorkdayDates.checkout(WorkdayDates.date("2026-10-17", timezone: "Europe/Berlin")!,
                                  day: "2026-10-15", timezone: "Europe/Berlin", payload: draft)
    }
    #expect(throws: TracyError.self) {
        try WorkdayDates.checkout(WorkdayDates.date("2026-10-15", minutes: 1200, timezone: "Europe/Berlin")!,
                                  day: "2026-10-15", timezone: "Europe/Berlin", payload: draft)
    }
    #expect(WorkdayDates.date("2026-02-30", timezone: "UTC") == nil)
}

@Test func vacationRangeValidationAndEncoding() throws {
    let range = try VacationRange(start: "2026-10-15", end: "2026-10-20")
    let json = try JSONSerialization.jsonObject(with: TracyAPI.encode(range)) as! [String: String]
    #expect(json == ["start": "2026-10-15", "end": "2026-10-20"])
    #expect(throws: TracyError.self) { try VacationRange(start: "2026-10-20", end: "2026-10-15") }
    #expect(throws: TracyError.self) { try VacationRange(start: "2026-02-30", end: "2026-03-01") }
    #expect(throws: TracyError.self) { try VacationRange(start: "2026-01-01", end: "2028-01-01") }
}
