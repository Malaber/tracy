import SwiftUI
import TracyCore

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.credential == nil {
                SignInView()
            } else {
                TabView {
                    TodayView().tabItem { Label("Today", systemImage: "clock") }
                    RecentDaysView().tabItem { Label("Recent Days", systemImage: "calendar") }
                    StatisticsView().tabItem { Label("Statistics", systemImage: "chart.bar") }
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .alert(
            "Tracy", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .task {
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if scenePhase == .active { await store.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
    }
}

struct SyncStatus: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if store.pendingCount > 0 || store.notice != nil || store.isSyncing {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        store.isSyncing
                            ? "Syncing…"
                            : store.pendingCount > 0
                                ? "\(store.pendingCount) days waiting to sync" : "Saved data",
                        systemImage: store.isSyncing ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up"
                    )
                    .font(.headline)
                    if let notice = store.notice {
                        Text(notice).font(.subheadline).foregroundStyle(.primary)
                    }
                    if store.needsSignIn {
                        Text("Open Settings to sign in again.").font(.subheadline)
                    } else {
                        Button("Retry sync") { Task { await store.refresh() } }.disabled(store.isSyncing)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: WorkEntry?
    private var entry: WorkEntry { store.entry(store.today) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(Clock.title(store.today))
                            .font(.subheadline).foregroundStyle(.primary)
                        Text(headline).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text(subtitle).foregroundStyle(Color(uiColor: .label)).padding(.bottom, 12)
                        if entry.checkIn == nil || entry.checkOut == nil {
                            Button {
                                store.quickAction(checkOut: entry.checkIn != nil)
                            } label: {
                                Text(entry.checkIn == nil ? "Check in now" : "Check out now")
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .modifier(PrimaryActionStyle())
                            .accessibilityIdentifier("quickAction")
                        }
                    }
                    .padding(.vertical, 12)
                }
                Section {
                    dayValue("Check-in", value: entry.checkIn ?? "Not entered")
                    dayValue(
                        "Check-out",
                        value: (entry.checkOut ?? "Not entered")
                            + (entry.checkOutNextDay ? " · next day" : ""))
                    if !store.isPending(store.today) {
                        dayValue("Breaks", value: Clock.duration(entry.breakMinutes))
                        if let billable = entry.billableMinutes {
                            dayValue("Billable", value: Clock.duration(billable))
                        }
                    }
                    if !entry.notes.isEmpty { Text(entry.notes) }
                    Button("Edit today’s entry") { editing = entry }
                        .accessibilityIdentifier("editToday")
                } header: {
                    Text("Your day").foregroundStyle(Color(uiColor: .label))
                }
                if let remote = store.conflict(store.today) {
                    Section {
                        NavigationLink {
                            ConflictView(date: store.today, remote: remote)
                        } label: {
                            Label(
                                "Review a sync conflict",
                                systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                    }
                }
                let attention =
                    store.snapshot.recent?.days.filter {
                        $0.needsAttention(today: store.today) && !store.isPending($0.date)
                    } ?? []
                if !attention.isEmpty {
                    Section {
                        NavigationLink {
                            RecentDaysView()
                        } label: {
                            Text("\(attention.count) recent days need a look")
                        }
                    }
                }
                SyncStatus()
            }
            .navigationTitle("Today")
            .refreshable { await store.refresh() }
            .sheet(item: $editing) { EntryEditor(entry: $0) }
        }
    }

    private func dayValue(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(.primary)
        }
    }

    private var headline: String {
        if store.isPending(store.today) {
            return entry.checkOut == nil ? "Your day is underway" : "Your day, recorded"
        }
        if let minutes = entry.exactMinutes { return Clock.duration(minutes) }
        return entry.checkIn == nil ? "Ready when you are" : "Your day is underway"
    }
    private var subtitle: String {
        if store.isPending(store.today) { return "Saved on this device. Totals update after sync." }
        if entry.checkOut != nil { return "Working time recorded for today." }
        return entry.checkIn == nil
            ? "One tap to start. A moment to review."
            : "Checked in at \(entry.checkIn ?? ""). Check out when you finish."
    }
}

struct PrimaryActionStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).foregroundStyle(
                colorScheme == .dark ? Color.black : Color.white)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct RecentDaysView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: WorkEntry?
    @State private var onlyAttention = false
    @State private var chosenDate = Date()
    @State private var loadingDate = false

    private var dates: [String] {
        let calendar = Clock.calendar(timezone: store.snapshot.timezone)
        return (0..<14).map {
            Clock.day(
                calendar.date(byAdding: .day, value: -$0, to: Date())!, timezone: store.snapshot.timezone)
        }
    }

    private func summary(_ date: String) -> DaySummary? {
        store.snapshot.recent?.days.first { $0.date == date }
    }
    private func needsAttention(_ date: String) -> Bool {
        store.conflict(date) != nil || (store.entry(date).status == "in_progress" && date < store.today)
            || (summary(date)?.needsAttention(today: store.today) == true && !store.isPending(date))
    }

    var body: some View {
        NavigationStack {
            List {
                SyncStatus()
                let olderPending = Set(store.snapshot.pending.map(\.date)).filter { !dates.contains($0) }
                    .sorted(by: >)
                if !olderPending.isEmpty {
                    Section("Older entries waiting to sync") {
                        ForEach(olderPending, id: \.self) { date in
                            if let remote = store.conflict(date) {
                                NavigationLink {
                                    ConflictView(date: date, remote: remote)
                                } label: {
                                    row(date)
                                }
                            } else {
                                Button {
                                    Task { await open(date) }
                                } label: {
                                    row(date)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Needs attention only", isOn: $onlyAttention)
                    Text("Review the past two weeks, or open any date below.")
                        .font(.subheadline).foregroundStyle(.primary)
                }
                Section("Recent days") {
                    let visible = dates.filter { !onlyAttention || needsAttention($0) }
                    if visible.isEmpty {
                        ContentUnavailableView(
                            "All caught up", systemImage: "checkmark.circle",
                            description: Text("No recent entries need attention in the saved calendar."))
                    }
                    ForEach(visible, id: \.self) { date in
                        if let conflict = store.conflict(date) {
                            NavigationLink {
                                ConflictView(date: date, remote: conflict)
                            } label: {
                                row(date)
                            }
                        } else {
                            Button {
                                Task { await open(date) }
                            } label: {
                                row(date)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens this day for review and correction")
                        }
                    }
                }
                Section("Another date") {
                    DatePicker("Work date", selection: $chosenDate, in: ...Date(), displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: store.snapshot.timezone)!)
                    Button("Open entry") {
                        Task { await open(Clock.day(chosenDate, timezone: store.snapshot.timezone)) }
                    }.disabled(loadingDate)
                }
            }
            .navigationTitle("Recent Days")
            .refreshable { await store.refresh() }
            .sheet(item: $editing) { EntryEditor(entry: $0) }
        }
    }

    private func open(_ date: String) async {
        loadingDate = true
        editing = await store.loadEntry(date)
        loadingDate = false
    }

    private func row(_ date: String) -> some View {
        let entry = store.entry(date)
        let pending = store.isPending(date)
        let conflict = store.conflict(date) != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(Clock.title(date)).font(.headline)
            if let start = entry.checkIn {
                Text(
                    "\(start) – \(entry.checkOut ?? "Check-out missing")\(entry.checkOutNextDay ? " (+1 day)" : "")"
                )
                .font(.subheadline).monospacedDigit()
            }
            Label(
                conflict
                    ? "Review conflict"
                    : pending
                        ? "Waiting to sync"
                        : summary(date)?.label(today: store.today) ?? "Calendar not yet downloaded",
                systemImage: conflict
                    ? "exclamationmark.triangle"
                    : pending
                        ? "icloud.and.arrow.up"
                        : entry.status == "complete"
                            ? "checkmark.circle"
                            : needsAttention(date) ? "exclamationmark.circle" : "calendar"
            )
            .font(.subheadline).foregroundStyle(needsAttention(date) ? Color.primary : Color.secondary)
            if let exact = entry.exactMinutes, !pending {
                Text(Clock.duration(exact)).font(.subheadline).foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ConflictView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let date: String
    let remote: WorkEntry
    @State private var confirmLocal = false

    var body: some View {
        List {
            Section {
                Text(
                    "This day was also changed on another device. Compare both versions and choose which to keep."
                )
            }
            details("On this device", entry: store.entry(date))
            details("On the server", entry: remote)
            Section {
                Button("Keep my offline entry") { confirmLocal = true }
                Button("Use server entry", role: .destructive) {
                    store.resolve(date: date, useLocal: false, server: remote)
                    dismiss()
                }
            } footer: {
                Text("If the server changes again before syncing, Tracy will ask you to review it again.")
            }
        }
        .navigationTitle(Clock.title(date))
        .confirmationDialog(
            "Replace the server entry with your offline version?", isPresented: $confirmLocal,
            titleVisibility: .visible
        ) {
            Button("Keep my offline entry") {
                store.resolve(date: date, useLocal: true, server: remote)
                dismiss()
            }
        }
    }

    private func details(_ title: String, entry: WorkEntry) -> some View {
        Section(title) {
            LabeledContent("Check-in", value: entry.checkIn ?? "None")
            LabeledContent(
                "Check-out", value: (entry.checkOut ?? "None") + (entry.checkOutNextDay ? " (+1 day)" : ""))
            ForEach(Array(entry.breaks.enumerated()), id: \.offset) { _, item in
                LabeledContent(
                    "Break",
                    value: item.mode == "duration"
                        ? "\(item.durationMinutes ?? 0) minutes" : "\(item.start ?? "") – \(item.end ?? "")")
            }
            if !entry.notes.isEmpty { Text(entry.notes) }
        }
    }
}
