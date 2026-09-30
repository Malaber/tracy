import Foundation

public struct PendingEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: String
    public let payload: EntryPayload
    public var baseRevision: String
    public var conflict: WorkEntry?
    public var error: String?
}

public struct JournalSnapshot: Codable, Sendable {
    public var entries: [String: WorkEntry] = [:]
    public var pending: [PendingEntry] = []
    public var timezone = "Europe/Berlin"
    public var recent: Statistics?
    public var lastSync: Date?
    public init() {}
}

/// One file per server/account. A write succeeds on disk before the UI reports success.
@MainActor
public final class OfflineJournal {
    public private(set) var snapshot: JournalSnapshot
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            snapshot = try JSONDecoder().decode(JournalSnapshot.self, from: Data(contentsOf: file))
        } else {
            snapshot = JournalSnapshot()
        }
    }

    private func commit(_ next: JournalSnapshot) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: file, options: .atomic)
        #endif
        snapshot = next
    }

    public func entry(_ date: String) -> WorkEntry {
        var entry = snapshot.entries[date] ?? .empty(date: date)
        if let pending = snapshot.pending.last(where: { $0.date == date }) {
            entry.checkIn = pending.payload.checkIn
            entry.checkOut = pending.payload.checkOut
            entry.checkOutNextDay = pending.payload.checkOutNextDay
            entry.breaks = pending.payload.breaks
            entry.notes = pending.payload.notes
            entry.status =
                entry.checkIn == nil ? "empty" : (entry.checkOut == nil ? "in_progress" : "complete")
            // Totals remain server-authoritative; never show stale totals for an edited day.
            entry.exactMinutes = nil
            entry.billableMinutes = nil
        }
        return entry
    }

    public func enqueue(date: String, payload: EntryPayload, baseRevision: String? = nil) throws {
        if let message = payload.validationMessage { throw TracyError.server(message) }
        let payload = payload.applyingDefaultBreak(previous: entry(date).payload)
        var next = snapshot
        // A corrected edit replaces a definitively rejected request. Uncertain requests
        // remain in order so a lost response can still be recovered idempotently.
        if let rejected = next.pending.first(where: { $0.date == date && $0.error != nil }) {
            next.pending.removeAll { $0.date == date }
            next.pending.append(
                PendingEntry(id: UUID(), date: date, payload: payload, baseRevision: rejected.baseRevision))
            try commit(next)
            return
        }
        next.pending.append(
            PendingEntry(
                id: UUID(), date: date, payload: payload,
                baseRevision: baseRevision ?? next.entries[date]?.revision ?? "missing"))
        try commit(next)
    }

    public func cache(entries: [WorkEntry], recent: Statistics? = nil, timezone: String? = nil) throws {
        var next = snapshot
        for entry in entries { next.entries[entry.date] = entry }
        if let recent { next.recent = recent }
        if let timezone { next.timezone = timezone }
        next.lastSync = Date()
        try commit(next)
    }

    public func acknowledge(_ operation: PendingEntry, entry: WorkEntry) throws {
        var next = snapshot
        next.entries[entry.date] = entry
        next.pending.removeAll { $0.id == operation.id }
        if let index = next.pending.firstIndex(where: { $0.date == entry.date }) {
            next.pending[index].baseRevision = entry.revision
        }
        try commit(next)
    }

    public func block(_ operation: PendingEntry, conflict: WorkEntry? = nil, error: String? = nil) throws {
        var next = snapshot
        if let index = next.pending.firstIndex(where: { $0.id == operation.id }) {
            next.pending[index].conflict = conflict
            next.pending[index].error = error
        }
        try commit(next)
    }

    /// Choosing either version is explicit and only removes operations for this day.
    public func resolve(date: String, useLocal: Bool, server: WorkEntry) throws {
        var next = snapshot
        let local = next.pending.last(where: { $0.date == date })?.payload
        next.pending.removeAll { $0.date == date }
        next.entries[date] = server
        if useLocal, let local {
            next.pending.append(
                PendingEntry(id: UUID(), date: date, payload: local, baseRevision: server.revision))
        }
        try commit(next)
    }

    public func retryErrors() throws {
        var next = snapshot
        for index in next.pending.indices { next.pending[index].error = nil }
        try commit(next)
    }
}
