import SwiftUI
import TracyCore

struct VacationEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemoval = false

    init(initialDay: String) {
        let date = WorkdayDates.date(initialDay, timezone: "UTC") ?? Date()
        _start = State(initialValue: date)
        _end = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("First day", selection: $start, displayedComponents: .date)
                    DatePicker("Last day", selection: $end, displayedComponents: .date)
                }
                Section {
                    Button("Mark vacation") { Task { await save(marked: true) } }
                        .accessibilityIdentifier("saveVacation")
                    Button("Remove vacation", role: .destructive) { confirmRemoval = true }
                    Text("Vacation changes calendar targets. Recorded working time and unsaved entry edits stay unchanged.")
                        .font(.footnote)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("Saving vacation…") }
            }
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .disabled(saving)
            .navigationTitle("Vacation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .confirmationDialog("Remove vacation for these dates?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove vacation", role: .destructive) { Task { await save(marked: false) } }
            }
        }
    }

    private func save(marked: Bool) async {
        saving = true
        defer { saving = false }
        do {
            try await store.setVacation(start: Clock.day(start, timezone: "UTC"),
                                        end: Clock.day(end, timezone: "UTC"), marked: marked)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct NotificationCheckoutView: View {
    @EnvironmentObject private var store: AppStore
    let request: CheckoutRequest
    @State private var entry: WorkEntry?

    var body: some View {
        Group {
            if request.account != store.notificationAccount {
                ContentUnavailableView("Sign in to the original account", systemImage: "person.crop.circle",
                                       description: Text("This reminder belongs to another account."))
            } else if let entry {
                EntryEditor(entry: entry, checkoutPrompt: true, timezone: store.snapshot.timezone)
            } else {
                ProgressView("Loading working day…")
            }
        }
        .task(id: request.id) {
            guard request.account == store.notificationAccount else { return }
            entry = await store.loadEntry(request.day)
        }
    }
}
