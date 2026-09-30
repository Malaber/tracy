import SwiftUI
import TracyCore

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let entry: WorkEntry
    @State private var draft: EntryPayload
    @State private var confirmDiscard = false
    @State private var error: String?

    init(entry: WorkEntry) {
        self.entry = entry
        _draft = State(initialValue: entry.payload)
    }

    private var changed: Bool { draft != entry.payload }
    private var validation: String? { draft.validationMessage }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Clock.title(entry.date)).font(.headline)
                    Label("Saved on this device first", systemImage: "iphone")
                    Text(
                        "Your entry syncs automatically when Tracy can connect. Times use \(store.snapshot.timezone)."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Working time") {
                    Toggle(
                        "Check-in entered",
                        isOn: Binding(
                            get: { draft.checkIn != nil },
                            set: { enabled in
                                draft.checkIn = enabled ? "08:00" : nil
                            }))
                    if draft.checkIn != nil { ClockPicker(title: "Check-in", value: clockBinding(\.checkIn)) }
                    Toggle(
                        "Check-out entered",
                        isOn: Binding(
                            get: { draft.checkOut != nil },
                            set: { enabled in
                                draft.checkOut = enabled ? "17:00" : nil
                                if !enabled { draft.checkOutNextDay = false }
                            }))
                    if draft.checkOut != nil {
                        ClockPicker(title: "Check-out", value: clockBinding(\.checkOut))
                        Toggle("Check-out is next day", isOn: $draft.checkOutNextDay)
                    }
                }
                Section {
                    ForEach(draft.breaks.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(
                                "Break \(index + 1)",
                                selection: Binding(
                                    get: { draft.breaks[index].mode },
                                    set: { mode in
                                        draft.breaks[index] =
                                            mode == "duration"
                                            ? WorkBreak()
                                            : WorkBreak(
                                                mode: "range", durationMinutes: nil, start: "12:00",
                                                end: "12:30")
                                    })
                            ) {
                                Text("Duration").tag("duration")
                                Text("Start and end").tag("range")
                            }
                            if draft.breaks[index].mode == "duration" {
                                Stepper(
                                    "\(draft.breaks[index].durationMinutes ?? 30) minutes",
                                    value: Binding(
                                        get: { draft.breaks[index].durationMinutes ?? 30 },
                                        set: { draft.breaks[index].durationMinutes = $0 }
                                    ), in: 1...1440
                                )
                                .accessibilityLabel("Break \(index + 1) duration")
                                .accessibilityValue("\(draft.breaks[index].durationMinutes ?? 30) minutes")
                            } else {
                                ClockPicker(
                                    title: "Break starts",
                                    value: Binding(
                                        get: { draft.breaks[index].start ?? "12:00" },
                                        set: { draft.breaks[index].start = $0 }))
                                ClockPicker(
                                    title: "Break ends",
                                    value: Binding(
                                        get: { draft.breaks[index].end ?? "12:30" },
                                        set: { draft.breaks[index].end = $0 }))
                            }
                            Button("Remove break \(index + 1)", role: .destructive) {
                                draft.breaks.remove(at: index)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Button("Add break", systemImage: "plus") { draft.breaks.append(WorkBreak()) }
                        .disabled(draft.breaks.count >= 20 || draft.checkOut == nil)
                } header: {
                    Text("Breaks")
                } footer: {
                    Text(
                        "When a day is first completed with more than 4½ hours and no break, Tracy adds a 30-minute break. You can adjust it after syncing. Overnight break ranges are supported."
                    )
                }
                Section("Notes") {
                    TextField("What would you like to remember?", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("entryNotes")
                    Text("\(draft.notes.count) / 2,000").font(.caption).foregroundStyle(.secondary)
                }
                if let validation {
                    Section { Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .accessibilityIdentifier("entryForm")
            .navigationTitle("Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.save(date: entry.date, payload: draft, baseRevision: entry.revision)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(validation != nil).accessibilityIdentifier("saveEntry")
                }
            }
            .interactiveDismissDisabled(changed)
            .confirmationDialog(
                "Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
        }
    }

    private func clockBinding(_ keyPath: WritableKeyPath<EntryPayload, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "08:00" }, set: { draft[keyPath: keyPath] = $0 })
    }
}

struct ClockPicker: View {
    let title: String
    @Binding var value: String
    private var calendar: Calendar { Clock.calendar(timezone: "UTC") }
    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: {
                    let minutes = Clock.minutes(value) ?? 0
                    return calendar.date(
                        from: DateComponents(
                            year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))!
                },
                set: { date in
                    let components = calendar.dateComponents([.hour, .minute], from: date)
                    value = String(format: "%02d:%02d", components.hour!, components.minute!)
                }), displayedComponents: .hourAndMinute
        )
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
    }
}
