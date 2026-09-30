import Foundation

public protocol EntrySyncService: Sendable {
    func entry(_ date: String) async throws -> WorkEntry
    func save(_ date: String, payload: EntryPayload, revision: String, mutationID: UUID) async throws
        -> WorkEntry
}

extension TracyAPI: EntrySyncService {}

@MainActor
public enum JournalSynchronizer {
    public static func synchronize(_ journal: OfflineJournal, using service: any EntrySyncService)
        async throws
    {
        var blockedDates = Set(
            journal.snapshot.pending.filter { $0.conflict != nil || $0.error != nil }.map(\.date))
        while let operation = journal.snapshot.pending.first(where: { !blockedDates.contains($0.date) }) {
            try Task.checkCancellation()
            do {
                let saved = try await service.save(
                    operation.date, payload: operation.payload,
                    revision: operation.baseRevision, mutationID: operation.id)
                try journal.acknowledge(operation, entry: saved)
            } catch TracyError.conflict {
                let remote = try await service.entry(operation.date)
                try journal.block(operation, conflict: remote)
                blockedDates.insert(operation.date)
            } catch TracyError.rejected(let message) {
                try journal.block(operation, error: message)
                blockedDates.insert(operation.date)
            }
        }
    }
}
