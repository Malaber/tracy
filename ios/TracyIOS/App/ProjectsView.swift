import SwiftUI
import TracyCore

struct ProjectsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var search = ""
    var body: some View {
        Form {
            Section("New project") {
                TextField("Project name", text: $name).accessibilityIdentifier("projectName")
                Button("Create project") {
                    mutate("projects", "POST", ["name": name.trimmingCharacters(in: .whitespacesAndNewlines)])
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("createProject")
            }
            Section {
                Button("No default project") { mutate("projects/default", "PUT", ["project_id": NSNull()]) }
                Text("Default applies to new days. Remaining billable time goes to that project. Archived projects remain in historical bookings.")
                    .font(.footnote)
            }
            ForEach([false, true], id: \.self) { archived in
                Section(archived ? "Archived" : "Active projects") {
                    ForEach(store.projects.filter { $0.archived == archived && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { project in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(project.name).font(.headline)
                            if store.snapshot.projectCatalog?.defaultProjectId == project.id { Text("Default project").font(.caption) }
                            if !project.archived {
                                Button("Make default") { mutate("projects/default", "PUT", ["project_id": project.id]) }
                                    .buttonStyle(.borderless).accessibilityIdentifier("projectDefault\(project.id)")
                            }
                            Button(project.archived ? "Unarchive" : "Archive") {
                                mutate("projects/\(project.id)", "PUT", ["name": project.name, "archived": !project.archived])
                            }.buttonStyle(.borderless).accessibilityIdentifier("projectArchive\(project.id)")
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(busy)
        .navigationTitle("Projects")
        .searchable(text: $search, prompt: "Find project")
    }
    private func mutate(_ path: String, _ method: String, _ body: [String: Any]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.updateProjects(path: path, method: method, body: JSONSerialization.data(withJSONObject: body))
                error = nil
                if method == "POST" { name = "" }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct EditableBooking: Identifiable {
    let id = UUID()
    var projectId: Int
    var minutes: Int
}

struct ProjectBookingSection: View {
    @EnvironmentObject private var store: AppStore
    @Binding var defaultProjectId: Int?
    @Binding var bookings: [EditableBooking]
    var body: some View {
        Section {
            Picker("Remaining billable time", selection: $defaultProjectId) {
                Text("Unassigned").tag(Int?.none)
                ForEach(store.projects.filter { !$0.archived || $0.id == defaultProjectId }) { project in
                    Text(project.name + (project.archived ? " (archived)" : "")).tag(Optional(project.id))
                }
            }
            ForEach($bookings) { $booking in
                VStack(alignment: .leading) {
                    Picker("Project", selection: $booking.projectId) {
                        Text("Choose project").tag(0)
                        ForEach(store.projects.filter { !$0.archived || $0.id == booking.projectId }) { project in
                            Text(project.name + (project.archived ? " (archived)" : "")).tag(project.id)
                        }
                    }
                    HStack {
                        Text("Billable minutes")
                        TextField("Minutes", value: $booking.minutes, format: .number).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityLabel("Booking minutes")
                    }
                    Text(Clock.duration(booking.minutes)).font(.caption)
                    Button("Remove booking", role: .destructive) { bookings.removeAll { $0.id == booking.id } }
                        .buttonStyle(.borderless)
                }
            }
            Button("Book to another project") {
                bookings.append(EditableBooking(projectId: store.projects.first(where: { !$0.archived })?.id ?? 0, minutes: 120))
            }.disabled(bookings.count >= 50)
                .accessibilityIdentifier("addProjectBooking")
            NavigationLink("Manage projects") { ProjectsView() }
        } header: { Text("Project bookings") } footer: {
            Text("Enter billable minutes for each project, for example 120 for two hours. The remaining billable time goes to the selected project above.")
        }
    }
}
