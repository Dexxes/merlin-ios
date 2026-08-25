import Foundation
import UserNotifications

// MARK: – Error

enum ReminderError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "Bitte erlaube Benachrichtigungen in den Einstellungen, um Erinnerungen zu setzen."
    }
}

// MARK: – Service

/// Manages article reminders: persists them to disk (JSON, same pattern as
/// ArticleCacheService) and schedules / cancels local notifications via
/// UNUserNotificationCenter.
actor ReminderService {

    static let shared = ReminderService()
    private init() {}

    // MARK: – In-memory store (loaded lazily from disk)

    private var reminders: [UUID: Reminder] = [:]
    private var isLoaded = false

    // MARK: – Disk location

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("merlin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminders.json")
    }

    // MARK: – Public API

    /// All pending reminders sorted by trigger date (soonest first).
    func all() -> [Reminder] {
        loadIfNeeded()
        return reminders.values
            .filter { $0.status == .pending }
            .sorted { $0.triggerAt < $1.triggerAt }
    }

    /// The pending reminder for a specific article, or nil.
    func reminder(for articleId: Int) -> Reminder? {
        loadIfNeeded()
        return reminders.values.first { $0.articleId == articleId && $0.status == .pending }
    }

    /// Requests notification permission (first time only), then schedules a
    /// local UNCalendarNotificationTrigger for `date`.
    ///
    /// If a pending reminder already exists for this article it is cancelled
    /// first, so calling schedule again acts as an update.
    func schedule(for article: Article, at date: Date) async throws {
        loadIfNeeded()

        let center = UNUserNotificationCenter.current()

        // Request permission if not yet determined
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { throw ReminderError.permissionDenied }
        } else if settings.authorizationStatus == .denied {
            throw ReminderError.permissionDenied
        }

        // Cancel existing reminder for this article (if any)
        if let existing = reminder(for: article.id) {
            cancelNotification(id: existing.id)
            reminders[existing.id]?.status = .cancelled
        }

        let reminder = Reminder(
            articleId:    article.id,
            articleTitle: article.displayTitle,
            triggerAt:    date
        )

        // Build the notification
        let content       = UNMutableNotificationContent()
        content.title     = reminder.articleTitle
        content.body      = "Dein gespeicherter Artikel wartet auf dich."
        content.sound     = .default
        content.userInfo  = ["articleId": article.id]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.id.uuidString,
            content:    content,
            trigger:    trigger
        )

        try await center.add(request)

        reminders[reminder.id] = reminder
        saveToDisk()
    }

    /// Cancels the pending reminder for a specific article (no-op if none).
    func cancel(for articleId: Int) {
        loadIfNeeded()
        guard let existing = reminder(for: articleId) else { return }
        cancelNotification(id: existing.id)
        reminders[existing.id]?.status = .cancelled
        saveToDisk()
    }

    /// Called by the notification delegate when the user taps the notification.
    /// Marks the reminder as fired so it no longer appears in the pending list.
    func markFired(notificationId: String) {
        loadIfNeeded()
        guard let uuid = UUID(uuidString: notificationId) else { return }
        reminders[uuid]?.status = .fired
        saveToDisk()
    }

    // MARK: – Internal

    private func cancelNotification(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    // MARK: – Persistence

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data    = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Reminder].self, from: data)
        else { return }
        for r in decoded { reminders[r.id] = r }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(Array(reminders.values)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
