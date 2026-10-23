import Foundation
import Testing

@testable import TracyCore

@Test func entryValidation() {
    #expect(EntryPayload(checkOut: "17:00").validationMessage != nil)
    #expect(EntryPayload(checkIn: "09:00", checkOut: "08:00").validationMessage != nil)
    #expect(EntryPayload(checkIn: "22:00", checkOut: "06:00", checkOutNextDay: true).validationMessage == nil)
    #expect(
        EntryPayload(checkIn: "08:00", checkOut: "09:00", breaks: [.init(durationMinutes: 60)])
            .validationMessage != nil)
    #expect(EntryPayload(checkIn: "08:00", breaks: [.init()]).validationMessage == nil)
    #expect(
        EntryPayload(
            checkIn: "22:00", checkOut: "06:00", checkOutNextDay: true,
            breaks: [.init(mode: "range", durationMinutes: nil, start: "23:45", end: "00:15")]
        ).validationMessage == nil)
    #expect(EntryPayload(notes: String(repeating: "a", count: 2001)).validationMessage != nil)
}

@Test func serverAddressAndClock() throws {
    #expect(try ServerAddress.parse(" https://tracy.example/ ").host == "tracy.example")
    for invalid in [
        "http://tracy.example", "https://user:password@tracy.example", "https://tracy.example/path",
        "https://tracy.example?token=secret", "https://tracy.example/#fragment",
    ] {
        #expect(throws: TracyError.self) { try ServerAddress.parse(invalid) }
    }
    let now = ISO8601DateFormatter().date(from: "2026-09-29T23:30:00Z")!
    #expect(Clock.day(now, timezone: "Europe/Berlin") == "2026-09-30")
    #expect(Clock.day(now, timezone: "America/New_York") == "2026-09-29")
    #expect(Clock.duration(-90) == "−1h 30m")
    #expect(Clock.minutes("24:00") == nil)
}

@Test func calendarReviewUsesServerRules() throws {
    func day(date: String = "2026-09-28", status: String = "empty", expected: Int = 480, off: Bool = false)
        throws -> DaySummary
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "date": date, "weekday": "Monday", "is_weekend": false,
            "is_day_off": off, "is_workday": !off, "expected_minutes": expected,
            "exact_minutes": status == "complete" ? 480 : 0, "billable_minutes": status == "complete" ? 480 : 0,
            "balance_minutes": -expected,
            "status": status, "notes": "",
        ])
        return try TracyAPI.decoder.decode(DaySummary.self, from: data)
    }
    #expect(try day().needsAttention(today: "2026-09-30"))
    #expect(try !day(status: "complete").needsAttention(today: "2026-09-30"))
    #expect(try day(status: "complete", expected: 600).needsAttention(today: "2026-09-30"))
    #expect(try day(status: "complete", expected: 600).label(today: "2026-09-30") == "Below target by 2h 0m")
    #expect(try !day(expected: 0, off: true).needsAttention(today: "2026-09-30"))
    #expect(try day(status: "in_progress", expected: 0, off: true).needsAttention(today: "2026-09-30"))
    #expect(try !day(date: "2026-09-30").needsAttention(today: "2026-09-30"))
}

@MainActor
private func journal() throws -> (OfflineJournal, URL) {
    let file = FileManager.default.temporaryDirectory.appending(path: "tracy-tests-\(UUID()).json")
    return (try OfflineJournal(file: file), file)
}

@Test @MainActor func offlineJournalSurvivesRestartAndPreservesBreakRanges() throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let payload = EntryPayload(
        checkIn: "08:00", checkOut: "17:00",
        breaks: [
            .init(mode: "range", durationMinutes: nil, start: "12:00", end: "12:45")
        ], notes: "Offline notes")
    try journal.enqueue(date: "2026-09-29", payload: payload)
    let restored = try OfflineJournal(file: file)
    #expect(restored.snapshot.pending.count == 1)
    #expect(restored.entry("2026-09-29").payload == payload)
    #expect(restored.snapshot.pending[0].id == journal.snapshot.pending[0].id)
    #expect(restored.entry("2026-09-29").exactMinutes == 495)
}

@Test @MainActor func corruptionAndDiskErrorsDoNotDiscardExistingEntries() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "tracy-corrupt-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("broken".utf8).write(to: file)
    #expect(throws: (any Error).self) { try OfflineJournal(file: file) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    let unwritable = try OfflineJournal(file: file.appending(path: "nested.json"))
    #expect(throws: (any Error).self) {
        try unwritable.enqueue(date: "2026-09-29", payload: EntryPayload(checkIn: "08:00"))
    }
    #expect(unwritable.snapshot.pending.isEmpty)
}

private actor MockServer: EntrySyncService {
    var entries: [String: WorkEntry] = [:]
    var requests: [UUID] = []
    var failAfterSaving = false
    var failNetwork = false
    var reject = false

    func configure(failAfterSaving: Bool = false, failNetwork: Bool = false, reject: Bool = false) {
        self.failAfterSaving = failAfterSaving
        self.failNetwork = failNetwork
        self.reject = reject
    }
    func change(_ entry: WorkEntry) { entries[entry.date] = entry }
    func entry(_ date: String) async throws -> WorkEntry { entries[date] ?? .empty(date: date) }
    func save(_ date: String, payload: EntryPayload, revision: String, mutationID: UUID) async throws
        -> WorkEntry
    {
        requests.append(mutationID)
        if failNetwork { throw URLError(.notConnectedToInternet) }
        if reject { throw TracyError.rejected("Invalid entry") }
        var current = entries[date] ?? .empty(date: date)
        if current.clientMutationId == mutationID.uuidString { return current }
        guard current.revision == revision else { throw TracyError.conflict }
        current.checkIn = payload.checkIn
        current.checkOut = payload.checkOut
        current.checkOutNextDay = payload.checkOutNextDay
        current.breaks = payload.breaks
        current.notes = payload.notes
        current.revision = UUID().uuidString
        current.clientMutationId = mutationID.uuidString
        current.saved = true
        entries[date] = current
        if failAfterSaving {
            failAfterSaving = false
            throw URLError(.networkConnectionLost)
        }
        return current
    }
}

@Test @MainActor func syncRetriesLostResponseWithoutDuplicatingOrLosingNewerEdits() async throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let server = MockServer()
    try journal.enqueue(date: "2026-09-29", payload: .init(checkIn: "08:00", notes: "First"))
    let originalID = journal.snapshot.pending[0].id
    await server.configure(failAfterSaving: true)
    await #expect(throws: URLError.self) { try await JournalSynchronizer.synchronize(journal, using: server) }
    #expect(journal.snapshot.pending.count == 1)
    // A later edit is added before retrying an uncertain response.
    try journal.enqueue(
        date: "2026-09-29", payload: .init(checkIn: "08:00", checkOut: "17:00", notes: "Second"))
    let restored = try OfflineJournal(file: file)
    try await JournalSynchronizer.synchronize(restored, using: server)
    #expect(restored.snapshot.pending.isEmpty)
    #expect(try await server.entry("2026-09-29").notes == "Second")
    #expect(await server.requests.filter { $0 == originalID }.count == 2)
}

@Test @MainActor func conflictBlocksOnlyItsDayAndSurvivesRestart() async throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let server = MockServer()
    var remote = WorkEntry.empty(date: "2026-09-29")
    remote.revision = "web-revision"
    remote.notes = "Web entry"
    await server.change(remote)
    try journal.enqueue(date: remote.date, payload: .init(checkIn: "08:00", notes: "Offline first"))
    try journal.enqueue(date: remote.date, payload: .init(checkIn: "08:00", notes: "Offline latest"))
    try journal.enqueue(date: "2026-09-30", payload: .init(checkIn: "09:00"))
    try await JournalSynchronizer.synchronize(journal, using: server)
    #expect(journal.snapshot.pending.count == 2)
    #expect(journal.snapshot.pending[0].conflict?.notes == "Web entry")
    let restored = try OfflineJournal(file: file)
    try await JournalSynchronizer.synchronize(restored, using: server)
    #expect(await server.requests.count == 2)  // Conflicted day's dependent edit never sends.
    try restored.resolve(date: remote.date, useLocal: true, server: remote)
    try await JournalSynchronizer.synchronize(restored, using: server)
    #expect(restored.snapshot.pending.isEmpty)
    #expect(try await server.entry(remote.date).notes == "Offline latest")
}

@Test @MainActor func offlineAndRejectedRequestsKeepDataAndCanBeCorrected() async throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let server = MockServer()
    try journal.enqueue(date: "2026-09-29", payload: .init(checkIn: "08:00", notes: "Keep me"))
    await server.configure(failNetwork: true)
    await #expect(throws: URLError.self) { try await JournalSynchronizer.synchronize(journal, using: server) }
    #expect(journal.snapshot.pending.count == 1)
    await server.configure(reject: true)
    try await JournalSynchronizer.synchronize(journal, using: server)
    #expect(journal.snapshot.pending.first?.error == "Invalid entry")
    try journal.enqueue(date: "2026-09-29", payload: .init(checkIn: "09:00", notes: "Corrected"))
    #expect(journal.snapshot.pending.count == 1)
    await server.configure()
    try await JournalSynchronizer.synchronize(journal, using: server)
    #expect(journal.snapshot.pending.isEmpty)
    #expect(journal.entry("2026-09-29").notes == "Corrected")
}

@Test @MainActor func defaultBreakSurvivesSubsequentOfflineEdits() throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let day = "2026-09-29"
    try journal.enqueue(date: day, payload: .init(checkIn: "08:00"))
    try journal.enqueue(date: day, payload: .init(checkIn: "08:00", checkOut: "17:00"))
    #expect(journal.entry(day).breaks == [.init(automatic: true, durationMinutes: 30)])
    var edited = journal.entry(day).payload
    edited.notes = "A later note"
    try journal.enqueue(date: day, payload: edited)
    #expect(journal.snapshot.pending.last?.payload.breaks == [.init(automatic: true, durationMinutes: 30)])
    edited.breaks = []
    try journal.enqueue(date: day, payload: edited)
    #expect(journal.entry(day).breaks.isEmpty)  // An explicit correction stays intentional.
    #expect(
        EntryPayload(checkIn: "08:00", checkOut: "12:30").applyingDefaultBreak(previous: .init()).breaks
            .isEmpty)
}

@Test @MainActor func useServerResolutionPreservesOtherPendingDays() throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    try journal.enqueue(date: "2026-09-29", payload: .init(checkIn: "08:00"))
    try journal.enqueue(date: "2026-09-30", payload: .init(checkIn: "09:00"))
    var remote = WorkEntry.empty(date: "2026-09-29")
    remote.notes = "Keep server"
    try journal.resolve(date: remote.date, useLocal: false, server: remote)
    #expect(journal.snapshot.pending.map(\.date) == ["2026-09-30"])
    #expect(journal.entry(remote.date).notes == "Keep server")
}

@Test @MainActor func journalsAreIsolatedByAccount() throws {
    let (first, firstFile) = try journal()
    let (second, secondFile) = try journal()
    defer {
        try? FileManager.default.removeItem(at: firstFile)
        try? FileManager.default.removeItem(at: secondFile)
    }
    try first.enqueue(date: "2026-09-29", payload: .init(checkIn: "08:00", notes: "First account"))
    #expect(second.snapshot.pending.isEmpty)
    #expect(second.entry("2026-09-29").notes.isEmpty)
}

@Test @MainActor func editorUsesRevisionItOpenedEvenIfBackgroundRefreshChangesCache() async throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    var original = WorkEntry.empty(date: "2026-09-29")
    original.revision = "opened-revision"
    try journal.cache(entries: [original])
    let server = MockServer()
    var refreshed = original
    refreshed.revision = "new-web-revision"
    refreshed.notes = "New web edit"
    await server.change(refreshed)
    try journal.cache(entries: [refreshed])
    try journal.enqueue(
        date: original.date, payload: .init(checkIn: "08:00", notes: "Edited old screen"),
        baseRevision: original.revision)
    try await JournalSynchronizer.synchronize(journal, using: server)
    #expect(journal.snapshot.pending.first?.conflict?.notes == "New web edit")
    #expect(try await server.entry(original.date).notes == "New web edit")
}

@MainActor @Test func accountCacheErasurePersists() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "erase-\(UUID().uuidString).json")
    let journal = try OfflineJournal(file: file)
    try journal.cache(entries: [.empty(date: "2026-09-30")])
    #expect(FileManager.default.fileExists(atPath: file.path))
    try journal.erase()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try OfflineJournal(file: file).snapshot.entries.isEmpty)
}

@Test func liveSignOffEstimate() {
    var entry = WorkEntry.empty(date: "2026-10-12")
    entry.checkIn = "08:00"
    func at(_ clock: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-10-12T\(clock):00Z")!
    }
    func estimate(_ clock: String, rounding: Int = 15) -> SignOffEstimate? {
        SignOffEstimate.project(entry, now: at(clock), timezone: "UTC", rounding: rounding)
    }
    #expect(estimate("08:00")?.exactMinutes == 0)
    #expect(estimate("12:30")?.exactMinutes == 270)
    #expect(estimate("12:59")?.breakMinutes == 0)
    #expect(estimate("14:00")?.exactMinutes == 360)
    #expect(estimate("14:01")?.exactMinutes == 331)
    #expect(estimate("14:01")?.billableMinutes == 345)
    #expect(estimate("14:01")?.breakMinutes == 30)
    #expect(estimate("16:31", rounding: 1)?.billableMinutes == 481)
    #expect(estimate("16:31")?.progress == 1)
    #expect(estimate("07:59") == nil)
    #expect(entry.checkOut == nil && entry.breaks.isEmpty)
    #expect(SignOffEstimate.project(entry, now: at("12:31"), timezone: "Pacific/Auckland") == nil)
    entry.breaks = [.init(durationMinutes: 45)]
    #expect(estimate("16:00")?.exactMinutes == 435)
    entry.checkOut = "17:00"
    #expect(estimate("18:00") == nil)
}

@Test func statisticsIncludeEstimateOnce() throws {
    let fixture = """
    {"start":"2026-10-12","end":"2026-10-18",
     "summary":{"exact_minutes":480,"billable_minutes":480,"target_minutes":2400,"balance_minutes":-1920,"completed_days":1},
     "days":[{"date":"2026-10-12","weekday":"Monday","is_weekend":false,"holiday":null,"is_day_off":false,"is_workday":true,"expected_minutes":480,"exact_minutes":0,"billable_minutes":0,"balance_minutes":-480,"status":"in_progress","notes":""}]}
    """
    let saved = try TracyAPI.decoder.decode(Statistics.self, from: Data(fixture.utf8))
    let estimate = SignOffEstimate(exactMinutes: 241, billableMinutes: 255, breakMinutes: 30)
    let projected = saved.projecting(estimate, date: "2026-10-12")
    #expect(projected.summary.exactMinutes == 721)
    #expect(projected.summary.billableMinutes == 735)
    #expect(projected.summary.balanceMinutes == -1665)
    #expect(projected.summary.completedDays == 1)
    #expect(projected.days[0].status == "in_progress")
    #expect(projected.days[0].balanceMinutes == -225)
    #expect(projected.projecting(estimate, date: "2026-10-12").summary.exactMinutes == 721)
    #expect(saved.summary.exactMinutes == 480)
    #expect(saved.projecting(estimate, date: "2025-01-01").summary.exactMinutes == 480)
}

@Test @MainActor func reopenAndRepeatedResume() throws {
    let closed = EntryPayload(checkIn: "08:00", checkOut: "13:00",
                              breaks: [.init(durationMinutes: 30)], notes: "Keep")
    let undo = try closed.reopened()
    #expect(undo.checkIn == "08:00")
    #expect(undo.checkOut == nil)
    #expect(undo.breaks == closed.breaks)
    #expect(undo.notes == "Keep")
    var resumed = try closed.reopened(resumeAt: "14:00")
    #expect(resumed.breaks.count == 2)
    #expect(resumed.breaks.last?.start == "13:00")
    #expect(resumed.breaks.last?.end == "14:00")
    resumed.checkOut = "16:00"
    resumed = try resumed.reopened(resumeAt: "16:30")
    #expect(resumed.breaks.count == 3)
    #expect(try closed.reopened(resumeAt: "13:00").breaks.count == 1)
    #expect(throws: TracyError.self) { try closed.reopened(resumeAt: "12:00") }
    #expect(throws: TracyError.self) { try undo.reopened() }
    var overnight = closed
    overnight.checkOutNextDay = true
    #expect(throws: TracyError.self) { try overnight.reopened(resumeAt: "14:00") }
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    try journal.enqueue(date: "2026-10-15", payload: resumed)
    let restored = try OfflineJournal(file: file)
    #expect(restored.entry("2026-10-15").payload == resumed)
    var entry = restored.entry("2026-10-15")
    let now = ISO8601DateFormatter().date(from: "2026-10-15T17:00:00Z")!
    #expect(SignOffEstimate.project(entry, now: now, timezone: "UTC")?.exactMinutes == 420)
    entry.checkOut = "17:00"
    #expect(entry.payload.validationMessage == nil)
}

@Test @MainActor func removedBreakDoesNotLeaveStaleDeductionOffline() throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    let day = "2026-10-15"
    var saved = WorkEntry.empty(date: day)
    saved.checkIn = "08:00"
    saved.checkOut = "17:00"
    saved.breaks = [.init(durationMinutes: 30)]
    saved.breakMinutes = 30
    try journal.cache(entries: [saved])
    var payload = saved.payload
    payload.breaks = []
    try journal.enqueue(date: day, payload: payload)
    #expect(journal.entry(day).breaks.isEmpty)
    #expect(journal.entry(day).breakMinutes == 0)
    let reopened = try OfflineJournal(file: file)
    #expect(reopened.entry(day).breakMinutes == 0)
    payload.breaks = [.init(mode: "range", durationMinutes: nil, start: "23:50", end: "00:10")]
    try reopened.enqueue(date: day, payload: payload)
    #expect(reopened.entry(day).breakMinutes == 20)
}

@Test @MainActor func projectBookingsSurviveOfflineAndValidateBillableLimit() throws {
    let (journal, file) = try journal()
    defer { try? FileManager.default.removeItem(at: file) }
    try journal.cacheProjects(ProjectCatalog(projects: [Project(id: 1, name: "X"), Project(id: 2, name: "Y")], defaultProjectId: 1))
    let payload = EntryPayload(checkIn: "08:00", checkOut: "12:00", projectAllocations: [.init(projectId: 2, minutes: 120)], defaultProjectId: 1)
    try journal.enqueue(date: "2026-10-22", payload: payload)
    let reopened = try OfflineJournal(file: file)
    #expect(reopened.entry("2026-10-22").projectAllocations == payload.projectAllocations)
    #expect(reopened.entry("2026-10-22").defaultProjectId == 1)
    #expect(reopened.snapshot.projectCatalog?.projects.count == 2)
    var invalid = payload
    invalid.projectAllocations = [.init(projectId: 2, minutes: 241)]
    #expect(invalid.bookingValidation(rounding: 15) != nil)
    invalid.checkOut = "12:01"
    #expect(invalid.bookingValidation(rounding: 15) == nil)
    invalid.projectAllocations = [.init(projectId: 0, minutes: 120)]
    #expect(invalid.validationMessage != nil)
    let data = try TracyAPI.encode(EntryPayload(projectAllocations: []))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["default_project_id"] is NSNull)
}

@Test func automaticBreakDisappearsWhenCheckoutShortened() {
    var payload = EntryPayload(checkIn: "08:44", checkOut: "17:00").applyingDefaultBreak(previous: .init())
    #expect(payload.breaks.first?.automatic == true)
    payload.checkOut = "14:16"
    #expect(payload.removingPrematureAutomaticBreaks.breaks.isEmpty)
    #expect(payload.removingPrematureAutomaticBreaks.exactMinutes == 332)
    payload.checkOut = "14:44"
    #expect(payload.removingPrematureAutomaticBreaks.breaks.isEmpty)
    payload.breaks[0].automatic = false
    #expect(payload.removingPrematureAutomaticBreaks.breaks.count == 1)
}

@Test func roundedBillableDayMeetsReviewTarget() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "date": "2026-10-22", "weekday": "Thursday", "is_weekend": false,
        "is_day_off": false, "is_workday": true, "expected_minutes": 480,
        "exact_minutes": 474, "billable_minutes": 480, "balance_minutes": 0,
        "status": "complete", "notes": "",
    ])
    let day = try TracyAPI.decoder.decode(DaySummary.self, from: data)
    #expect(!day.needsAttention(today: "2026-10-23"))
    #expect(day.label(today: "2026-10-23") == "Entered")
}
