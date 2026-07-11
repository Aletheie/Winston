import SwiftUI

struct AnimatedDashedBorder: View {
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 2
    let color: Color
    var dash: [CGFloat] = [10, 6]

    @State private var dashPhase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: lineWidth, dash: dash, dashPhase: dashPhase)
            )
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    dashPhase = -64
                }
            }
    }
}

#Preview {
    AnimatedDashedBorder(cornerRadius: 20, color: Theme.purple.accent)
        .frame(width: 340, height: 170)
        .padding(24)
        .background(Theme.purple.background)
}
