import SwiftUI

struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigator.self) private var navigator
    @State private var reminders: [Reminder] = []

    var body: some View {
        NavigationStack {
            Group {
                if reminders.isEmpty {
                    ContentUnavailableView(
                        L("reminders.list.emptyTitle"),
                        systemImage: "bell.slash",
                        description: Text(L("reminders.list.emptyMessage"))
                    )
                } else {
                    List {
                        ForEach(reminders) { reminder in
                            Button {
                                openArticle(reminder)
                            } label: {
                                reminderRow(reminder)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteReminders)
                    }
                }
            }
            .navigationTitle(L("reminders.list.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
                if !reminders.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                }
            }
        }
        .task { await loadReminders() }
    }

    // MARK: – Row

    @ViewBuilder
    private func reminderRow(_ reminder: Reminder) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.13))
                    .frame(width: 36, height: 36)
                Image(systemName: "bell.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 17))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.articleTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(reminder.triggerAt, style: .date)
                    Text("·")
                    Text(reminder.triggerAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: – Actions

    private func loadReminders() async {
        let all = await ReminderService.shared.all()
        await MainActor.run { reminders = all }
    }

    private func deleteReminders(at offsets: IndexSet) {
        let toDelete = offsets.map { reminders[$0] }
        reminders.remove(atOffsets: offsets)
        Task {
            for r in toDelete {
                await ReminderService.shared.cancel(for: r.articleId)
            }
        }
    }

    /// Opens the reminder's article in the reader — reuses the same deep-link
    /// path ArticleListView already handles for a tapped reminder notification.
    private func openArticle(_ reminder: Reminder) {
        navigator.articleIdToOpen = reminder.articleId
        dismiss()
    }
}
