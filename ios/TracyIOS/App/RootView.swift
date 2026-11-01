import SwiftUI
import TracyCore

struct RootView: View {
    @State private var selectedTab = "today"
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var notifications: WorkdayNotifications
    @AppStorage("workdayReminders") private var remindersEnabled = false

    var body: some View {
        Group {
            if store.credential == nil {
                SignInView()
            } else {
                TabView(selection: $selectedTab) {
                    TodayView(selectedTab: $selectedTab).tabItem { Label("Today", systemImage: "clock") }.tag("today")
                    RecentDaysView().tabItem { Label("Recent Days", systemImage: "calendar") }.tag("recent")
                    StatisticsView().tabItem { Label("Statistics", systemImage: "chart.bar") }.tag("statistics")
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
                }
            }
        }
        .task(id: store.reminderKey + String(remindersEnabled) + String(describing: scenePhase)) {
            if !store.isDemo {
                await notifications.synchronize(entry: store.reminderEntry, timezone: store.snapshot.timezone,
                                                account: store.notificationAccount, enabled: remindersEnabled)
            }
        }
        .sheet(item: $notifications.checkoutRequest) { request in
            NotificationCheckoutView(request: request)
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
            if store.isDemo {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-notification-checkout"),
                    let account = store.notificationAccount {
                    notifications.openCheckout(day: store.today, account: account)
                }
                #endif
                return
            }
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
    private var title: String {
        store.isSyncing ? "Syncing…" : store.pendingCount > 0
            ? "\(store.pendingCount) \(store.pendingCount == 1 ? "day" : "days") waiting to sync" : "Saved data"
    }
    var body: some View {
        if store.pendingCount > 0 || store.notice != nil || store.isSyncing {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        title,
                        systemImage: store.isSyncing ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up"
                    )
                    .font(.headline)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("syncStatusTitle")
                    if let notice = store.notice {
                        Text(notice).font(.subheadline).foregroundStyle(Color.primary)
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
    @Binding var selectedTab: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var totalSize = 44
    @State private var editing: WorkEntry?
    @State private var showSessionAction = false
    @State private var showVacation = false
    private var entry: WorkEntry { store.entry(store.today) }
    private var active: Bool { entry.checkIn != nil && entry.checkOut == nil }
    private var started: Bool { entry.checkIn != nil }
    private var minutes: Int { store.signOffEstimate?.billableMinutes ?? entry.billableMinutes ?? 0 }
    private var breaks: Int { store.signOffEstimate?.breakMinutes ?? entry.breakMinutes }
    private var progress: Double { min(1, max(0, Double(minutes) / 480)) }

    var body: some View {
        Group {
            if widthClass == .regular && !typeSize.isAccessibilitySize {
                // Native split columns adapt their margins around Duo's folding region.
                NavigationSplitView {
                    List { clippingNegativeControl; dateHeader; heroSection; weeklySection }
                        .accessibilityIdentifier("todaySummary")
                        .modifier(TracyListStyle())
                        .navigationTitle("Today")
                        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
                        .toolbar { vacationToolbar }
                        .refreshable { await store.refresh() }
                } detail: {
                    List { detailsSection; actionsSection; reviewSections; SyncStatus() }
                        .accessibilityIdentifier("todayDetails")
                        .modifier(TracyListStyle())
                        .navigationTitle("Day details")
                        .refreshable { await store.refresh() }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    List {
                        clippingNegativeControl
                        dateHeader
                        heroSection
                        detailsSection
                        actionsSection
                        weeklySection
                        reviewSections
                        SyncStatus()
                    }
                    .modifier(TracyListStyle())
                    .navigationTitle("Today")
                    .toolbar { vacationToolbar }
                    .refreshable { await store.refresh() }
                }
            }
        }
        .sheet(isPresented: $showSessionAction) { SessionActionSheet(checkOut: active) }
        .sheet(isPresented: $showVacation) { VacationEditor(initialDay: store.today) }
        .sheet(item: $editing) { EntryEditor(entry: $0) }
    }

    @ViewBuilder private var clippingNegativeControl: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-contrast-negative-control") {
            Text("Deliberately low contrast")
                .foregroundStyle(Color(white: 0.97)).listRowBackground(Color.white)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-clipping-negative-control") {
            LayoutCheckedText("Deliberately clipped text proves measurement detects truncation", key: "negative")
                .lineLimit(1).frame(width: 40)
        }
        #endif
    }

    private var vacationToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Vacation", systemImage: "calendar.badge.plus") { showVacation = true }
                .accessibilityIdentifier("manageVacation")
        }
    }

    private var dateHeader: some View {
        LayoutCheckedText(Clock.title(store.today), key: "date")
            .font(.headline).foregroundStyle(Color.primary.opacity(0.72))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { total; status }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) { total; status }
                }
                let metricLayout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                metricLayout { breakMetric; goalMetric }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(Color(hue: (35 + 105 * progress) / 360, saturation: 0.75, brightness: 0.75))
                        .accessibilityHidden(true)
                    HStack {
                        Text(store.signOffEstimate != nil ? "If you check out now" : "Daily progress")
                        Spacer()
                        Text("8h").monospacedDigit()
                    }.font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("8-hour working day")
                .accessibilityValue("\(Int(progress * 100)) percent")
                .accessibilityAddTraits(.isStaticText)
                if !started {
                    VStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer").font(.title).accessibilityHidden(true)
                        Text("Ready to start the day?").font(.headline)
                        Text("Tap below to check in.").font(.subheadline).foregroundStyle(Color.primary.opacity(0.72))
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if minutes >= 480 {
                    Label(minutes == 480 ? "Daily goal reached" : "Goal exceeded by \(Clock.duration(minutes - 480))", systemImage: "trophy.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                if active || !started { quickAction }
            }
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 4) {
            LayoutCheckedText("Billable time", key: "billable")
                .font(.subheadline).foregroundStyle(Color.primary.opacity(0.72)).accessibilityIdentifier("heroBillable")
            LayoutCheckedText(Clock.duration(minutes), key: "headline")
                .font(.system(size: totalSize, weight: .bold, design: .rounded)).monospacedDigit()
                .accessibilityAddTraits(.isHeader).accessibilityLabel("Today's billable time, \(Clock.duration(minutes))")
        }
    }

    @ViewBuilder private var status: some View {
        if started {
            HStack(spacing: 8) {
                Image(systemName: active ? "clock.fill" : "checkmark.circle.fill")
                    .foregroundStyle(active ? Color("AccentColor") : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active ? "Working" : "Checked out").font(.subheadline.weight(.semibold))
                    Text("Since \((active ? entry.sessions?.last.map { WorkSession.clock($0.start) } ?? entry.checkIn : entry.checkOut) ?? "")")
                        .font(.caption)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background((active ? Color("AccentColor") : .green).opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workingStatus")
        }
    }

    private var breakMetric: some View {
        HStack(spacing: 10) {
            MetricIcon(symbol: "cup.and.saucer")
            VStack(alignment: .leading, spacing: 2) {
                LayoutCheckedText(Clock.duration(breaks), key: "breaks")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("\(Clock.duration(breaks)) breaks deducted")
                    .accessibilityIdentifier("heroBreaks")
                Text("Breaks deducted").font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
        }
    }
    private var goalMetric: some View {
        Label {
            VStack(alignment: .leading) {
                Text("8h 0m").font(.subheadline.weight(.semibold))
                Text("Daily goal").font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
        } icon: { MetricIcon(symbol: "target") }
    }

    private var actionTitle: some View {
        LayoutCheckedText(active ? "Check out now" : started ? "Check in again" : "Check in now", key: "action")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var quickAction: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button { store.quickAction(checkOut: active) } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        actionTitle
                    } else {
                        Label { actionTitle } icon: { Image(systemName: active ? "stop.fill" : "play.fill") }
                    }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.accessibilityIdentifier("quickAction")
            Button { showSessionAction = true } label: {
                HStack {
                    if typeSize.isAccessibilitySize { Text("Project and time options").fixedSize(horizontal: false, vertical: true) }
                    Image(systemName: "chevron.down")
                }
                .frame(minWidth: 28, minHeight: 44)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
            }
            .accessibilityLabel(active ? "Checkout project and time options" : "Check-in project and time options")
            .accessibilityIdentifier("sessionActionOptions")
        }
        .modifier(PrimaryActionStyle())
    }

    private var detailsSection: some View {
        Section {
            if !started {
                ContentUnavailableView("No entries yet", systemImage: "doc.badge.clock",
                                       description: Text("Check in to start tracking your working time."))
            } else {
                dayValue("Check-in", value: entry.checkIn ?? "Not entered", symbol: "rectangle.portrait.and.arrow.right")
                dayValue("Check-out", value: (entry.checkOut ?? "Working") + (entry.checkOutNextDay ? " · next day" : ""), symbol: "rectangle.portrait.and.arrow.forward")
                MetricRow(title: "Break time (deducted)", value: Clock.duration(breaks), symbol: "cup.and.saucer")
                MetricRow(title: "Total billable time", value: Clock.duration(minutes), symbol: "clock")
                ForEach(Array((entry.sessions ?? []).enumerated()), id: \.offset) { _, session in
                    let project = store.projects.first { $0.id == session.projectId }?.name ?? "Unassigned"
                    MetricRow(title: project, value: "\(WorkSession.clock(session.start)) – \(session.end.map(WorkSession.clock) ?? "Working")", symbol: "folder")
                }
                if !entry.notes.isEmpty { Text(entry.notes) }
            }
        } header: {
            LayoutCheckedText(started ? "Day details" : "Your day", key: "section").foregroundStyle(Color.primary)
        }
    }

    private var actionsSection: some View {
        Section {
            if started && !active {
                quickAction
                Button { store.reopenToday(recordGap: false) } label: { ActionRow(title: "Undo checkout", symbol: "arrow.uturn.backward") }
                    .accessibilityIdentifier("undoCheckout")
            }
            Button { editing = entry } label: {
                HStack(spacing: 12) {
                    MetricIcon(symbol: "pencil", tint: Color("AccentColor"))
                    LayoutCheckedText("Edit today’s entry", key: "edit").foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }.padding(.vertical, 4)
            }.accessibilityIdentifier("editToday")
        }
    }

    @ViewBuilder private var weeklySection: some View {
        if let saved = store.snapshot.week, saved.start <= store.today && store.today <= saved.end {
            let week = store.currentStatistics(saved)
            Section {
                Button { selectedTab = "statistics" } label: {
                    MetricRow(title: "Billable time", value: Clock.duration(week.summary.billableMinutes), symbol: "chart.bar.fill")
                }
                MetricRow(title: "Target", value: Clock.duration(week.summary.targetMinutes), symbol: "target")
                MetricRow(title: "Balance", value: Clock.duration(week.summary.billableMinutes - week.summary.targetMinutes), symbol: "plusminus")
            } header: {
                Text("This week").foregroundStyle(Color.primary)
            }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        if let remote = store.conflict(store.today) {
            Section {
                NavigationLink { ConflictView(date: store.today, remote: remote) } label: {
                    Label("Review a sync conflict", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
            }
        }
        let attention = store.snapshot.recent?.days.filter { $0.needsAttention(today: store.today) && !store.isPending($0.date) } ?? []
        if !attention.isEmpty {
            Section {
                Button { selectedTab = "recent" } label: {
                    LayoutCheckedText("\(attention.count) recent days need a look", key: "review").foregroundStyle(Color.primary)
                }
            }
        }
    }

    private func dayValue(_ label: String, value: String, symbol: String) -> some View {
        LabeledContent {
            LayoutCheckedText(value, key: "value.\(label)").foregroundStyle(Color.primary).monospacedDigit()
        } label: {
            Label { LayoutCheckedText(label, key: "label.\(label)") } icon: { MetricIcon(symbol: symbol) }
        }.padding(.vertical, 3)
            .accessibilityElement(children: .combine)
    }
}

struct PrimaryActionStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).foregroundStyle(
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
                calendar.date(byAdding: .day, value: -$0, to: store.currentDate)!,
                timezone: store.snapshot.timezone)
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
                        .font(.subheadline).foregroundStyle(Color.primary)
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
            .modifier(TracyListStyle())
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
            Label(Clock.title(date), systemImage: "calendar").font(.headline)
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
            if let exact = entry.billableMinutes, !pending {
                Text("\(Clock.duration(exact)) billable").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Color.primary)
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
