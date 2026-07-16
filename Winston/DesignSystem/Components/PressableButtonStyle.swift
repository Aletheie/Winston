import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.75),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle {
        PressableButtonStyle()
    }
}
