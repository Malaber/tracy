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
                    UserDefaults.standard.set("light", forKey: "appearance")
                    try openDemo()
                    return
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

    var notificationAccount: String? {
        guard let credential else { return nil }
        return SHA256.hash(data: Data("\(credential.server.absoluteString)|\(credential.userID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    var reminderEntry: WorkEntry {
        if entry(today).checkIn != nil { return entry(today) }
        let yesterday = Clock.calendar(timezone: snapshot.timezone).date(byAdding: .day, value: -1, to: currentDate)!
        let previous = entry(Clock.day(yesterday, timezone: snapshot.timezone))
        return previous.checkOut == nil ? previous : entry(today)
    }

    var reminderKey: String {
        let payload = (try? TracyAPI.encode(reminderEntry)) ?? Data()
        return (notificationAccount ?? "") + snapshot.timezone + payload.base64EncodedString()
    }

    func setVacation(start: String, end: String, marked: Bool) async throws {
        let range = try VacationRange(start: start, end: end)
        guard let journal else { throw TracyError.server("Sign in to manage vacation.") }
        if !isDemo {
            guard isOnline, !needsSignIn, let api else {
                throw TracyError.server("Connect to Tracy to save vacation.")
            }
            try await api.setVacation(range, marked: marked)
        }
        let calendar = Clock.calendar(timezone: "UTC")
        var cursor = WorkdayDates.date(range.start, timezone: "UTC")!
        var entries: [WorkEntry] = []
        while Clock.day(cursor, timezone: "UTC") <= range.end {
            let day = Clock.day(cursor, timezone: "UTC")
            var updated = snapshot.entries[day] ?? .empty(date: day)
            updated.isDayOff = marked
            entries.append(updated)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        try journal.cache(entries: entries)
        snapshot = journal.snapshot
        await refresh()
    }

    func entry(_ date: String) -> WorkEntry {
        var entry = journal?.entry(date) ?? .empty(date: date)
        if !entry.saved && !isPending(date) {
            entry.defaultProjectId = snapshot.projectCatalog?.defaultProjectId
        }
        return entry
    }

    var projects: [Project] { snapshot.projectCatalog?.projects ?? [] }

    func updateProjects(path: String, method: String, body: Data) async throws {
        guard let journal else { throw TracyError.server("Sign in to manage projects.") }
        let catalog: ProjectCatalog
        if isDemo {
            var current = snapshot.projectCatalog ?? ProjectCatalog()
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            if path == "projects/default" { current.defaultProjectId = json["project_id"] as? Int }
            else if method == "POST" {
                current.projects.append(Project(id: (current.projects.map(\.id).max() ?? 0) + 1, name: json["name"] as? String ?? "Project"))
            } else if let id = Int(path.split(separator: "/").last ?? ""), let index = current.projects.firstIndex(where: { $0.id == id }) {
                current.projects[index].archived = json["archived"] as? Bool ?? false
                if current.projects[index].archived && current.defaultProjectId == id { current.defaultProjectId = nil }
            }
            catalog = current
        } else {
            guard isOnline, let api else { throw TracyError.server("Connect to manage projects. Existing project bookings can be edited offline.") }
            catalog = try TracyAPI.decoder.decode(ProjectCatalog.self, from: await api.data(path, method: method, body: body))
        }
        try journal.cacheProjects(catalog)
        snapshot = journal.snapshot
    }
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

    var signOffEstimate: SignOffEstimate? {
        SignOffEstimate.project(entry(today), now: currentDate, timezone: snapshot.timezone,
                                rounding: snapshot.roundingMinutes ?? 15)
    }

    @discardableResult
    func quickAction(checkOut: Bool, minute: Int? = nil, projectId: Int? = nil, useSelectedProject: Bool = false) -> Bool {
        if !isDemo { currentDate = Date() }
        do {
            var payload = entry(today).payload
            let calendar = Clock.calendar(timezone: snapshot.timezone)
            let time = calendar.dateComponents([.hour, .minute], from: currentDate)
            let clock = String(format: "%02d:%02d", time.hour!, time.minute!)
            let selected = useSelectedProject ? projectId : (checkOut ? (payload.sessions != nil ? payload.sessions?.last?.projectId : payload.defaultProjectId) : snapshot.projectCatalog?.defaultProjectId)
            if checkOut && payload.sessions == nil && !useSelectedProject {
                payload.checkOut = clock
            } else {
                payload = try payload.sessionAction(checkOut: checkOut, minute: minute ?? Clock.minutes(clock)!, projectId: selected)
            }
            try save(date: today, payload: payload, baseRevision: entry(today).revision)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func reopenToday(recordGap: Bool) {
        if !isDemo { currentDate = Date() }
        let current = entry(today)
        do {
            let parts = Clock.calendar(timezone: snapshot.timezone).dateComponents([.hour, .minute], from: currentDate)
            let clock = String(format: "%02d:%02d", parts.hour!, parts.minute!)
            let payload = try current.payload.reopened(resumeAt: recordGap ? clock : nil)
            try save(date: today, payload: payload, baseRevision: current.revision)
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
        if !isDemo { currentDate = Date() }
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
            let preferences = try TracyAPI.decoder.decode(WorkPreferences.self, from: await api.data("preferences"))
            try journal.cacheRounding(preferences.roundingMinutes)
            if meta.projectBookings == true {
                let catalog = try TracyAPI.decoder.decode(ProjectCatalog.self, from: await api.data("projects"))
                try journal.cacheProjects(catalog)
            } else if journal.snapshot.pending.contains(where: { !($0.payload.projectAllocations ?? []).isEmpty || $0.payload.defaultProjectId != nil }) {
                notice = "Update the Tracy server before syncing project bookings. Your bookings remain saved on this device."
                return
            }
            if meta.workSessions != true && journal.snapshot.pending.contains(where: { $0.payload.sessions != nil }) {
                notice = "Update the Tracy server before syncing project sessions. Your sessions remain saved on this device."
                return
            }
            try await JournalSynchronizer.synchronize(journal, using: api)
            snapshot = journal.snapshot
            let end = Clock.day(Date(), timezone: meta.timezone)
            let startDate = Clock.calendar(timezone: meta.timezone).date(
                byAdding: .day, value: -13, to: Date())!
            let start = Clock.day(startDate, timezone: meta.timezone)
            let week = try await api.statistics(period: "week", anchor: end)
            try journal.cacheWeek(week)
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
            currentDate = Date(timeIntervalSince1970: 1_790_784_000)  // 2026-09-30 16:00 UTC
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
            if ProcessInfo.processInfo.arguments.contains("--ui-projects") {
                try journal.cacheProjects(ProjectCatalog(projects: [Project(id: 1, name: "Project X"), Project(id: 2, name: "Project Y")], defaultProjectId: 1))
            }
            let today = Clock.day(currentDate, timezone: "Europe/Berlin")
            var entry = WorkEntry.empty(date: today)
            entry.defaultProjectId = journal.snapshot.projectCatalog?.defaultProjectId
            entry.checkIn = "08:30"
            entry.status = "in_progress"
            if ProcessInfo.processInfo.arguments.contains("--ui-sessions") {
                entry.checkIn = nil
                entry.status = "empty"
                entry.sessions = []
            }
            entry.saved = true
            entry.revision = "demo"
            let calendar = Clock.calendar(timezone: "Europe/Berlin")
            var entries = [entry]
            var days: [[String: Any]] = []
            for offset in (0..<14).reversed() {
                let day = calendar.date(byAdding: .day, value: -offset, to: currentDate)!
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
