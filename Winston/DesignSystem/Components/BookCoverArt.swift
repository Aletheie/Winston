import SwiftUI

struct BookCoverArt: View {
    let accent1: Color
    let accent2: Color

    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [accent1.opacity(0.58), accent2.opacity(0.28), theme.backgroundAlt]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            let step = size.width / 5
            var grid = Path()
            for x in stride(from: step, to: size.width, by: step) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: step, to: size.height, by: step) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            var gridCtx = ctx
            gridCtx.opacity = 0.12
            gridCtx.stroke(grid, with: .color(accent1), lineWidth: 0.5)

            var spine = Path()
            spine.move(to: CGPoint(x: size.width * 0.2, y: 0))
            spine.addLine(to: CGPoint(x: size.width * 0.2, y: size.height))
            var spineCtx = ctx
            spineCtx.opacity = 0.28
            spineCtx.stroke(spine, with: .color(accent1), lineWidth: 0.8)

            let cx = size.width * 0.60, cy = size.height * 0.38
            let r = min(size.width, size.height) * 0.19

            var outer = Path()
            outer.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            var outerCtx = ctx
            outerCtx.opacity = 0.32
            outerCtx.stroke(outer, with: .color(accent2), lineWidth: 0.9)

            let ir = r * 0.55
            var inner = Path()
            inner.addEllipse(in: CGRect(x: cx - ir, y: cy - ir, width: ir * 2, height: ir * 2))
            var innerCtx = ctx
            innerCtx.opacity = 0.18
            innerCtx.stroke(inner, with: .color(accent1), lineWidth: 0.5)

            var cross = Path()
            cross.move(to: CGPoint(x: cx - r * 0.8, y: cy))
            cross.addLine(to: CGPoint(x: cx + r * 0.8, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - r * 0.8))
            cross.addLine(to: CGPoint(x: cx, y: cy + r * 0.8))
            var crossCtx = ctx
            crossCtx.opacity = 0.15
            crossCtx.stroke(cross, with: .color(accent1), lineWidth: 0.5)

            var dot = Path()
            dot.addEllipse(in: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4))
            var dotCtx = ctx
            dotCtx.opacity = 0.55
            dotCtx.fill(dot, with: .color(accent1))
        }
    }
}
