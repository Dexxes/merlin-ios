import SwiftUI

// MARK: – .onShake() View modifier

private struct ShakeModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                action()
            }
    }
}

extension View {
    /// Runs `action` whenever the device is shaken.
    func onShake(_ action: @escaping () -> Void) -> some View {
        modifier(ShakeModifier(action: action))
    }
}
