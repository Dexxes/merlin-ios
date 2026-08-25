import SwiftUI

struct ReminderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let article: Article
    /// Updated after scheduling / cancellation so the parent can reflect the new state.
    @Binding var currentReminder: Reminder?

    @State private var selectedDate = Date.defaultReminderDate
    @State private var isSaving     = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        L("reminders.sheet.dateTimeLabel"),
                        selection: $selectedDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                }

                if let msg = errorMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                if currentReminder != nil {
                    Section {
                        Button(role: .destructive) {
                            cancelReminder()
                        } label: {
                            Label(L("reminders.sheet.removeButton"), systemImage: "bell.slash")
                        }
                    }
                }
            }
            .navigationTitle(currentReminder == nil ? L("reminders.sheet.titleSet") : L("reminders.sheet.titleEdit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Button(L("common.save")) { scheduleReminder() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear {
            // Pre-fill picker with existing trigger date if updating
            if let existing = currentReminder {
                selectedDate = existing.triggerAt
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: – Actions

    private func scheduleReminder() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await ReminderService.shared.schedule(for: article, at: selectedDate)
                let updated = await ReminderService.shared.reminder(for: article.id)
                await MainActor.run {
                    currentReminder = updated
                    isSaving = false
                }
                dismiss()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private func cancelReminder() {
        // Fire-and-forget: update UI immediately, cancellation runs async in background
        Task { await ReminderService.shared.cancel(for: article.id) }
        currentReminder = nil
        dismiss()
    }
}

// MARK: – Date helper

private extension Date {
    /// Default reminder time: next day at 09:00.
    static var defaultReminderDate: Date {
        var comps        = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.day        = (comps.day ?? 1) + 1
        comps.hour       = 9
        comps.minute     = 0
        comps.second     = 0
        return Calendar.current.date(from: comps) ?? Date().addingTimeInterval(86_400)
    }
}
