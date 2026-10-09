import EventKit
import EventKitUI
import SwiftUI

/// Apple's "New Event" dialog, pre-filled from a `RecognizedTextEvent`. The
/// dialog runs outside the app (iOS 17+), so Merlin needs no calendar
/// permission; the user picks the calendar and saves or cancels there.
struct EventEditSheet: UIViewControllerRepresentable {
    let suggestion: RecognizedTextEvent
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = suggestion.title
        event.startDate = suggestion.start
        event.endDate = suggestion.end
        event.isAllDay = suggestion.isAllDay
        event.location = suggestion.location
        event.notes = suggestion.notes

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    @MainActor
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            onDone()
        }
    }
}

extension RecognizedTextEvent: Identifiable {
    var id: String { "\(title)|\(start.timeIntervalSince1970)" }
}
