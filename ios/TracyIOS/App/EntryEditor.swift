import SwiftUI
import TracyCore

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let entry: WorkEntry
    @State private var draft: EntryPayload
    @State private var confirmDiscard = false
    @State private var breakIDs: [UUID]
    @State private var breakToRemove: UUID?
    @State private var error: String?
    @State private var showVacation = false
    @State private var checkoutDate: Date
    let checkoutPrompt: Bool
    let timezone: String

    init(entry: WorkEntry, checkoutPrompt: Bool = false, timezone: String = "Europe/Berlin") {
        self.entry = entry
        self.checkoutPrompt = checkoutPrompt
        self.timezone = timezone
        _draft = State(initialValue: entry.payload)
        _breakIDs = State(initialValue: entry.breaks.map { _ in UUID() })
        let base = WorkdayDates.date(entry.date, minutes: (entry.checkOut.flatMap(Clock.minutes) ?? 17 * 60)
                                    + (entry.checkOutNextDay ? 1440 : 0), timezone: timezone) ?? Date()
        _checkoutDate = State(initialValue: base)
    }

    private var changed: Bool { draft != entry.payload }
    private var validation: String? { draft.validationMessage }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Clock.title(entry.date)).font(.headline)
                    Text(
                        "Your entry syncs automatically when Tracy can connect. Times use \(store.snapshot.timezone)."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if checkoutPrompt {
                    Section("Forgot to check out?") {
                        Text("Choose when you actually finished. Review the entry, then save.")
                        DatePicker("Actual checkout", selection: $checkoutDate, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
                            .accessibilityIdentifier("actualCheckout")
                        Button("Use this checkout") {
                            do {
                                draft = try WorkdayDates.checkout(checkoutDate, day: entry.date,
                                                                  timezone: timezone, payload: draft)
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("applyActualCheckout")
                    }
                }
                Section("Vacation") {
                    Button(store.entry(entry.date).isDayOff ? "Manage vacation" : "Mark vacation") {
                        showVacation = true
                    }.accessibilityIdentifier("entryVacation")
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
                    ForEach(breakIDs, id: \.self) { id in
                        let index = breakIDs.firstIndex(of: id) ?? 0
                        let item = breakBinding(id)
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Break \(index + 1)", selection: Binding(
                                get: { item.wrappedValue.mode },
                                set: { mode in
                                    item.wrappedValue = mode == "duration" ? WorkBreak()
                                        : WorkBreak(mode: "range", durationMinutes: nil,
                                                    start: "12:00", end: "12:30")
                                })) {
                                Text("Duration").tag("duration")
                                Text("Start and end").tag("range")
                            }
                            if item.wrappedValue.mode == "duration" {
                                Stepper("\(item.wrappedValue.durationMinutes ?? 30) minutes",
                                    value: Binding(
                                        get: { item.wrappedValue.durationMinutes ?? 30 },
                                        set: { value in
                                            if value == 0 { breakToRemove = id }
                                            else { item.wrappedValue.durationMinutes = value }
                                        }), in: 0...1440)
                                    .accessibilityLabel("Break \(index + 1) duration")
                                    .accessibilityValue("\(item.wrappedValue.durationMinutes ?? 30) minutes")
                                    .accessibilityIdentifier("breakDuration\(index + 1)")
                            } else {
                                ClockPicker(title: "Break starts", value: Binding(
                                    get: { item.wrappedValue.start ?? "12:00" },
                                    set: { item.wrappedValue.start = $0 }))
                                ClockPicker(title: "Break ends", value: Binding(
                                    get: { item.wrappedValue.end ?? "12:30" },
                                    set: { item.wrappedValue.end = $0 }))
                            }
                            Button("Remove break \(index + 1)", role: .destructive) {
                                removeBreak(id)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("removeBreak\(index + 1)")
                        }
                        .padding(.vertical, 6)
                        .swipeActions {
                            Button("Delete", role: .destructive) { removeBreak(id) }
                        }
                    }
                    Button("Add break", systemImage: "plus") {
                        draft.breaks.append(WorkBreak())
                        breakIDs.append(UUID())
                    }
                    .disabled(draft.breaks.count >= 20 || draft.checkIn == nil)
                } header: {
                    Text("Breaks")
                } footer: {
                    Text(
                        "When a day is first completed with more than six hours and no break, Tracy adds a 30-minute break. You can adjust it after syncing. Overnight break ranges are supported."
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
            .sheet(isPresented: $showVacation) { VacationEditor(initialDay: entry.date) }
            .confirmationDialog("Remove this break?", isPresented: Binding(
                get: { breakToRemove != nil },
                set: { if !$0 { breakToRemove = nil } }), titleVisibility: .visible) {
                if let id = breakToRemove {
                    Button("Remove break", role: .destructive) {
                        removeBreak(id)
                        breakToRemove = nil
                    }
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

    // Bind by identity: SwiftUI may retain a row binding after a neighbouring row is deleted.
    private func breakBinding(_ id: UUID) -> Binding<WorkBreak> {
        Binding(get: {
            guard let index = breakIDs.firstIndex(of: id) else { return WorkBreak() }
            return draft.breaks[index]
        }, set: { value in
            guard let index = breakIDs.firstIndex(of: id) else { return }
            draft.breaks[index] = value
        })
    }

    private func removeBreak(_ id: UUID) {
        guard let index = breakIDs.firstIndex(of: id) else { return }
        draft.breaks.remove(at: index)
        breakIDs.remove(at: index)
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
