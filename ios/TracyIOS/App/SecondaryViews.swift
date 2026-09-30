import Charts
import SwiftUI
import TracyCore

struct SignInView: View {
    @EnvironmentObject private var store: AppStore
    @State private var address = "https://tracy.malaber.de"
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "clock.badge.checkmark").font(.system(size: 48)).foregroundStyle(
                            Color("AccentColor")
                        ).accessibilityHidden(true)
                        Text("Make time for your day.").font(.largeTitle.bold())
                        Text("Quick entries. A clear view of recent days. Your time, in sync.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 24)
                }
                Section("Your Tracy server") {
                    TextField("https://tracy.example.com", text: $address)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Tracy server address")
                    Button {
                        signingIn = true
                        Task {
                            await store.signIn(address: address)
                            signingIn = false
                        }
                    } label: {
                        Label(
                            signingIn ? "Signing in…" : "Continue with passkey",
                            systemImage: "person.badge.key"
                        )
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .modifier(PrimaryActionStyle()).disabled(signingIn)
                }
                Section {
                    Text(
                        "Sign in or create an account securely in the system browser. After your first sign-in, you can record time offline and sync it later."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tracy")
            .onAppear { if let server = store.credential?.server { address = server.absoluteString } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmSignOut = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Color scheme", selection: $appearance) {
                        Text("Follow system").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appearancePicker")
                }
                Section("Sync") {
                    LabeledContent("Waiting to sync", value: "\(store.pendingCount) days")
                    if let synced = store.snapshot.lastSync {
                        LabeledContent("Last connected") { Text(synced, style: .relative) }
                    }
                    Button("Sync now") { Task { await store.refresh() } }.disabled(store.isSyncing)
                    Text(
                        "Entries stay on this device until they sync. Tracy retries when connectivity returns and whenever you reopen the app."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    ForEach(store.snapshot.pending.filter { $0.error != nil }) { pending in
                        VStack(alignment: .leading) {
                            Text(Clock.title(pending.date)).font(.headline)
                            Text(pending.error ?? "").font(.subheadline)
                        }
                    }
                }
                Section {
                    if let server = store.credential?.server {
                        LabeledContent("Server", value: server.host() ?? server.absoluteString)
                        LabeledContent("Time zone", value: store.snapshot.timezone)
                        if store.needsSignIn {
                            Button("Sign in again") {
                                signingIn = true
                                Task {
                                    await store.signIn(address: server.absoluteString)
                                    signingIn = false
                                }
                            }.disabled(signingIn)
                        }
                        Link("Account and work preferences", destination: server)
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .disabled(store.pendingCount > 0 || store.isSyncing)
                } header: {
                    Text("Account")
                } footer: {
                    Text("Sync pending entries before signing out or switching accounts.")
                }
                Section {
                    LabeledContent("App", value: "Tracy Time Tracking")
                    LabeledContent(
                        "Version",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Sign out of Tracy on this device?", isPresented: $confirmSignOut, titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            }
        }
    }
}

struct StatisticsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var period = "week"
    @State private var anchor = Date()
    @State private var statistics: Statistics?
    @State private var error: String?
    @State private var loading = false
    private var requestID: String { period + Clock.day(anchor, timezone: store.snapshot.timezone) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        Text("Week").tag("week")
                        Text("Month").tag("month")
                        Text("Year").tag("year")
                    }.pickerStyle(.segmented)
                    DatePicker("Containing date", selection: $anchor, displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: store.snapshot.timezone)!)
                }
                if loading { ProgressView("Loading statistics…") }
                if let error {
                    Section {
                        Text(error)
                        Button("Retry") { Task { await load() } }
                    }
                }
                if let statistics {
                    Section("\(Clock.title(statistics.start)) – \(Clock.title(statistics.end))") {
                        LabeledContent("Working time", value: Clock.duration(statistics.summary.exactMinutes))
                        LabeledContent(
                            "Billable time", value: Clock.duration(statistics.summary.billableMinutes))
                        LabeledContent(
                            "Full-period target", value: Clock.duration(statistics.summary.targetMinutes))
                        LabeledContent("Balance", value: Clock.duration(statistics.summary.balanceMinutes))
                        LabeledContent("Completed days", value: "\(statistics.summary.completedDays)")
                    }
                    if period != "year" {
                        Section("Working time by day") {
                            Chart(statistics.days) { day in
                                BarMark(
                                    x: .value("Day", Clock.date(day.date)),
                                    y: .value("Hours", Double(day.exactMinutes) / 60)
                                )
                                .foregroundStyle(Color("AccentColor"))
                                .accessibilityLabel(Clock.title(day.date))
                                .accessibilityValue(Clock.duration(day.exactMinutes))
                            }
                            .frame(height: 200)
                            .accessibilityLabel("Daily working time")
                        }
                    }
                }
                if store.pendingCount > 0 {
                    Section {
                        Label("Totals exclude entries waiting to sync.", systemImage: "icloud.and.arrow.up")
                    }
                }
                Section {
                    Text(
                        "Targets include the whole selected period, including upcoming workdays. Holidays and days off follow your server preferences."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Statistics")
            .task(id: requestID) { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        statistics = nil
        error = nil
        guard let api = store.api, !store.isDemo else {
            error = "Statistics will appear after connecting to your server."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.statistics(
                period: period, anchor: Clock.day(anchor, timezone: store.snapshot.timezone))
            guard !Task.isCancelled else { return }
            statistics = result
        } catch {
            if !Task.isCancelled {
                self.error =
                    "Statistics need a connection. Your offline time entries are still available in Today and Recent Days."
            }
        }
    }
}
