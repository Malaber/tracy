import SwiftUI
import TracyCore

struct SessionActionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let checkOut: Bool
    @State private var projectId: Int?
    @State private var time = Date()
    @State private var nextDay = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Project", selection: $projectId) {
                    Text("Unassigned").tag(Int?.none)
                    ForEach(store.projects.filter { !$0.archived || $0.id == projectId }) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }.accessibilityIdentifier("sessionProject")
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: store.snapshot.timezone) ?? .current)
                Toggle("Next day", isOn: $nextDay)
                Text("Choose a past or future time. Gaps between sessions are not billed.")
                    .font(.footnote)
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(checkOut ? "Check out" : "Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parts = Clock.calendar(timezone: store.snapshot.timezone).dateComponents([.hour, .minute], from: time)
                        let minute = parts.hour! * 60 + parts.minute! + (nextDay ? 1440 : 0)
                        if store.quickAction(checkOut: checkOut, minute: minute, projectId: projectId, useSelectedProject: true) { dismiss() }
                    }.accessibilityIdentifier("saveSessionAction")
                }
            }
            .onAppear {
                time = store.currentDate
                let entry = store.entry(store.today)
                projectId = checkOut ? (entry.sessions != nil ? entry.sessions?.last?.projectId : entry.defaultProjectId) : store.snapshot.projectCatalog?.defaultProjectId
                store.error = nil
            }
        }
    }
}

struct SessionEditorSection: View {
    @EnvironmentObject private var store: AppStore
    @Binding var sessions: [WorkSession]
    @State private var sessionIDs: [UUID]

    init(sessions: Binding<[WorkSession]>) {
        _sessions = sessions
        _sessionIDs = State(initialValue: sessions.wrappedValue.map { _ in UUID() })
    }

    private func binding(_ id: UUID) -> Binding<WorkSession> {
        Binding(get: {
            guard let index = sessionIDs.firstIndex(of: id), sessions.indices.contains(index) else {
                return WorkSession(projectId: nil, start: 0)
            }
            return sessions[index]
        }, set: { value in
            guard let index = sessionIDs.firstIndex(of: id), sessions.indices.contains(index) else { return }
            sessions[index] = value
        })
    }

    private func remove(_ id: UUID) {
        guard let index = sessionIDs.firstIndex(of: id), sessions.indices.contains(index) else { return }
        sessions.remove(at: index)
        sessionIDs.remove(at: index)
    }

    var body: some View {
        Section {
            ForEach(sessionIDs, id: \.self) { id in
                let index = sessionIDs.firstIndex(of: id) ?? 0
                let item = binding(id)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session \(index + 1)").font(.headline)
                    Picker("Project", selection: item.projectId) {
                        Text("Unassigned").tag(Int?.none)
                        ForEach(store.projects.filter { !$0.archived || $0.id == item.wrappedValue.projectId }) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    ClockPicker(title: "Check-in", value: Binding(
                        get: { WorkSession.clock(item.wrappedValue.start) },
                        set: { item.wrappedValue.start = (Clock.minutes($0) ?? 0) + (item.wrappedValue.start >= 1440 ? 1440 : 0) }))
                    Toggle("Starts next day", isOn: Binding(
                        get: { item.wrappedValue.start >= 1440 },
                        set: { item.wrappedValue.start = item.wrappedValue.start % 1440 + ($0 ? 1440 : 0) }))
                    Toggle("Checked out", isOn: Binding(
                        get: { item.wrappedValue.end != nil },
                        set: { item.wrappedValue.end = $0 ? min(2880, item.wrappedValue.start + 60) : nil }))
                    if let end = item.wrappedValue.end {
                        ClockPicker(title: "Check-out", value: Binding(
                            get: { WorkSession.clock(item.wrappedValue.end ?? end) },
                            set: { item.wrappedValue.end = (Clock.minutes($0) ?? 0) + ((item.wrappedValue.end ?? 0) >= 1440 ? 1440 : 0) }))
                        Toggle("Ends next day", isOn: Binding(
                            get: { (item.wrappedValue.end ?? 0) >= 1440 },
                            set: { item.wrappedValue.end = (item.wrappedValue.end ?? end) % 1440 + ($0 ? 1440 : 0) }))
                    }
                    Toggle("Automatic break after 6 hours", isOn: Binding(
                        get: { item.wrappedValue.breakMinutes == nil },
                        set: { item.wrappedValue.breakMinutes = $0 ? nil : 0 }))
                    if item.wrappedValue.breakMinutes != nil {
                        Stepper("\(item.wrappedValue.breakMinutes ?? 0) min break", value: Binding(
                            get: { item.wrappedValue.breakMinutes ?? 0 },
                            set: { item.wrappedValue.breakMinutes = $0 }), in: 0...1440)
                    }
                    Button("Remove session", role: .destructive) { remove(id) }
                        .buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
        } header: { Text("Project sessions") }
        footer: { Text("Gaps are unbilled. Each session longer than six hours gets a 30-minute automatic break. Turn it off to enter your own break, including zero.") }
    }
}
