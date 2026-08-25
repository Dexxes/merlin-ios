import UIKit

// MARK: – Haptic Feedback

enum HapticFeedback {
    /// Leichte Vibration für Bestätigungen (z.B. Favorit)
    @MainActor
    static func lightTap() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    /// Mittlere Vibration für Standard-Aktionen (z.B. Archivieren)
    @MainActor
    static func mediumTap() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }

    /// Schwere Vibration für destruktive Aktionen (z.B. Löschen)
    @MainActor
    static func heavyTap() {
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()
    }

    /// Erfolgs-Benachrichtigung (grünes Haken-Gefühl)
    @MainActor
    static func success() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
    }

    /// Fehler-Benachrichtigung (rotes X-Gefühl)
    @MainActor
    static func error() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.error)
    }

    /// Warnung (gelbes Ausrufezeichen-Gefühl)
    @MainActor
    static func warning() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.warning)
    }
}
