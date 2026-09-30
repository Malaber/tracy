import Combine
import CryptoKit
import Foundation
import Network
import TracyCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var credential: Credential?
    @Published private(set) var snapshot = JournalSnapshot()
    @Published private(set) var isOnline = true
    @Published private(set) var isSyncing = false
    @Published private(set) var needsSignIn = false
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var currentDate = Date()
    private var journal: OfflineJournal?
    private let monitor = NWPathMonitor()
    private let signInClient = BrowserSignIn()
    private(set) var isDemo = false

    var api: TracyAPI? { credential.map { TracyAPI(server: $0.server, token: $0.token) } }
    var today: String { Clock.day(currentDate, timezone: snapshot.timezone) }
    var pendingCount: Int { Set(snapshot.pending.map(\.date)).count }
    var conflicts: [PendingEntry] { snapshot.pending.filter { $0.conflict != nil } }

    init() {
        do {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                #if DEBUG
                    try openDemo()
                #endif
            } else if let saved = try CredentialStore.read() {
                try activate(saved)
            }
        } catch { self.error = error.localizedDescription }
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = connected
                if connected { await self.refresh() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "de.malaber.tracy.connectivity"))
    }

    private func activate(_ credential: Credential) throws {
        let key = Data(
            SHA256.hash(data: Data("\(credential.server.absoluteString)|\(credential.userID)".utf8))
        )
        .map { String(format: "%02x", $0) }.joined()
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Decode errors must never replace an existing journal with an empty one.
        let journal = try OfflineJournal(file: directory.appending(path: "Tracy/\(key).json"))
        self.journal = journal
        self.snapshot = journal.snapshot
        self.credential = credential
        self.needsSignIn = false
    }

    func signIn(address: String) async {
        do {
            let server = try ServerAddress.parse(address)
            let credential = try await signInClient.signIn(server: server)
            if pendingCount > 0, let current = self.credential,
                current.userID != credential.userID || current.server != credential.server
            {
                throw TracyError.server(
                    "Sign in to the same account to sync your pending entries before switching accounts.")
            }
            let api = TracyAPI(server: server, token: credential.token)
            let meta = try TracyAPI.decoder.decode(ServerMeta.self, from: await api.data("meta"))
            guard TimeZone(identifier: meta.timezone) != nil else {
                throw TracyError.server("The server returned an unsupported timezone.")
            }
            try activate(credential)
            try journal?.cache(entries: [], timezone: meta.timezone)
            snapshot = journal?.snapshot ?? snapshot
            try CredentialStore.save(credential)
            await refresh()
        } catch let error as NSError
            where error.domain == "com.apple.AuthenticationServices.WebAuthenticationSession"
            && error.code == 1
        {
            // The user cancelled the system sign-in sheet.
        } catch { self.error = error.localizedDescription }
    }

    func signOut() async {
        guard pendingCount == 0 else {
            error =
                "Sync your pending entries before signing out. Your entries are still saved on this device."
            return
        }
        do {
            if !isDemo, let api { _ = try await api.data("auth/mobile/logout", method: "POST") }
            try CredentialStore.remove()
            credential = nil
            journal = nil
            snapshot = JournalSnapshot()
            needsSignIn = false
            isDemo = false
        } catch TracyError.expired {
            do {
                try CredentialStore.remove()
                credential = nil
                journal = nil
                snapshot = JournalSnapshot()
                needsSignIn = false
            } catch { self.error = error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    func deleteAccount() async {
        guard pendingCount == 0, !isSyncing, let api, !isDemo else { return }
        do {
            _ = try await api.data("account", method: "DELETE")
            try journal?.erase()
            try CredentialStore.remove()
            credential = nil
            journal = nil
            snapshot = JournalSnapshot()
            needsSignIn = false
        } catch { self.error = error.localizedDescription }
    }

    func entry(_ date: String) -> WorkEntry { journal?.entry(date) ?? .empty(date: date) }
    func isPending(_ date: String) -> Bool { snapshot.pending.contains { $0.date == date } }
    func conflict(_ date: String) -> WorkEntry? {
        snapshot.pending.first { $0.date == date && $0.conflict != nil }?.conflict
    }

    func loadEntry(_ date: String) async -> WorkEntry {
        if isOnline, !isDemo, let api, let journal {
            do {
                let entry = try await api.entry(date)
                try journal.cache(entries: [entry])
                snapshot = journal.snapshot
            } catch TracyError.expired { needsSignIn = true } catch {
                notice = "Showing saved data. Changes will sync when a connection is available."
            }
        }
        return entry(date)
    }

    func save(date: String, payload: EntryPayload, baseRevision: String) throws {
        guard let journal else { throw TracyError.server("Sign in before entering time.") }
        try journal.enqueue(date: date, payload: payload, baseRevision: baseRevision)
        snapshot = journal.snapshot
        notice = "Saved on this device. Waiting to sync."
        Task { await refresh() }
    }

    func quickAction(checkOut: Bool) {
        currentDate = Date()
        do {
            var payload = entry(today).payload
            let calendar = Clock.calendar(timezone: snapshot.timezone)
            let time = calendar.dateComponents([.hour, .minute], from: Date())
            let clock = String(format: "%02d:%02d", time.hour!, time.minute!)
            if checkOut { payload.checkOut = clock } else { payload.checkIn = clock }
            try save(date: today, payload: payload, baseRevision: entry(today).revision)
        } catch { self.error = error.localizedDescription }
    }

    func resolve(date: String, useLocal: Bool, server: WorkEntry) {
        do {
            try journal?.resolve(date: date, useLocal: useLocal, server: server)
            snapshot = journal?.snapshot ?? snapshot
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        currentDate = Date()
        guard !isSyncing, isOnline, !isDemo, !needsSignIn, let api, let journal else { return }
        isSyncing = true
        defer {
            isSyncing = false
            snapshot = journal.snapshot
        }
        do {
            let meta = try TracyAPI.decoder.decode(ServerMeta.self, from: await api.data("meta"))
            guard TimeZone(identifier: meta.timezone) != nil else {
                throw TracyError.server("The server returned an unsupported timezone.")
            }
            try journal.cache(entries: [], timezone: meta.timezone)
            snapshot = journal.snapshot
            try await JournalSynchronizer.synchronize(journal, using: api)
            snapshot = journal.snapshot
            let end = Clock.day(Date(), timezone: meta.timezone)
            let startDate = Clock.calendar(timezone: meta.timezone).date(
                byAdding: .day, value: -13, to: Date())!
            let start = Clock.day(startDate, timezone: meta.timezone)
            async let recent = api.statistics(anchor: end, start: start)
            async let entriesData = api.data(
                "entries", query: [.init(name: "start", value: start), .init(name: "end", value: end)])
            let entries = try TracyAPI.decoder.decode([WorkEntry].self, from: await entriesData)
            // Include known missing days so a deletion on the web clears a cached entry.
            let stats = try await recent
            let byDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0) })
            let completeCache = stats.days.map { byDate[$0.date] ?? .empty(date: $0.date) }
            try journal.cache(entries: completeCache, recent: stats)
            notice =
                journal.snapshot.pending.isEmpty ? nil : "Some entries need attention before they can sync."
        } catch TracyError.expired {
            needsSignIn = true
            notice = "Sign in again to sync. Your offline entries are safe on this device."
        } catch {
            notice =
                "Could not reach Tracy. Your entries are saved on this device and will retry automatically."
        }
    }

    #if DEBUG
        private func openDemo() throws {
            isDemo = true
            let file = FileManager.default.temporaryDirectory.appending(
                path:
                    "tracy-ui-\(ProcessInfo.processInfo.environment["TRACY_UI_JOURNAL"] ?? UUID().uuidString).json"
            )
            let journal = try OfflineJournal(file: file)
            self.journal = journal
            self.credential = Credential(
                server: URL(string: "https://tracy.example")!, token: "demo", userID: "demo")
            if !journal.snapshot.entries.isEmpty {
                snapshot = journal.snapshot
                return
            }
            let today = Clock.day(Date(), timezone: "Europe/Berlin")
            var entry = WorkEntry.empty(date: today)
            entry.checkIn = "08:30"
            entry.status = "in_progress"
            entry.saved = true
            entry.revision = "demo"
            let calendar = Clock.calendar(timezone: "Europe/Berlin")
            var entries = [entry]
            var days: [[String: Any]] = []
            for offset in (0..<14).reversed() {
                let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
                let key = Clock.day(day, timezone: "Europe/Berlin")
                let weekend = calendar.isDateInWeekend(day)
                let dayOff = offset == 5
                let missing = offset == 1
                let complete = offset > 0 && !weekend && !dayOff && !missing
                let minutes = complete ? (offset == 2 ? 420 : 480) : 0
                if complete {
                    var historical = WorkEntry.empty(date: key)
                    historical.checkIn = "08:30"
                    historical.checkOut = offset == 2 ? "16:00" : "17:00"
                    historical.breaks = [WorkBreak()]
                    historical.breakMinutes = 30
                    historical.exactMinutes = minutes
                    historical.billableMinutes = minutes
                    historical.saved = true
                    historical.status = "complete"
                    historical.revision = "demo-\(offset)"
                    entries.append(historical)
                }
                days.append([
                    "date": key, "weekday": "", "is_weekend": weekend, "is_day_off": dayOff,
                    "is_workday": !weekend && !dayOff, "expected_minutes": weekend || dayOff ? 0 : 480,
                    "exact_minutes": minutes, "billable_minutes": minutes,
                    "balance_minutes": minutes - (weekend || dayOff ? 0 : 480),
                    "status": offset == 0 ? "in_progress" : complete ? "complete" : "empty", "notes": "",
                ])
            }
            let fixture: [String: Any] = [
                "start": days.first!["date"]!, "end": today, "days": days,
                "summary": [
                    "exact_minutes": 3780, "billable_minutes": 3780, "target_minutes": 4320,
                    "balance_minutes": -540, "completed_days": 8,
                ],
            ]
            let recent = try TracyAPI.decoder.decode(
                Statistics.self, from: JSONSerialization.data(withJSONObject: fixture))
            try journal.cache(entries: entries, recent: recent)
            snapshot = journal.snapshot
        }
    #endif
}
