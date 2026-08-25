import UIKit

// MARK: – Shake gesture → Notification

extension Notification.Name {
    /// Posted whenever the device is shaken.  Observed app-wide to trigger undo.
    static let deviceDidShake = Notification.Name("MerlinDeviceDidShake")
}

/// Extend UIWindow so shake events are forwarded as a Notification.
/// This is the recommended UIKit hook for detecting Motion events in SwiftUI apps.
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
