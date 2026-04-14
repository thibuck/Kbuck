import SwiftUI

struct AppChromeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            baseColor
                .ignoresSafeArea()

            Canvas { ctx, size in
                let spacing: CGFloat = colorScheme == .dark ? 36 : 44
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: .init(x: x, y: 0))
                    path.addLine(to: .init(x: x, y: size.height))
                    x += spacing
                }

                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: .init(x: 0, y: y))
                    path.addLine(to: .init(x: size.width, y: y))
                    y += spacing
                }

                ctx.stroke(path, with: .color(gridColor), lineWidth: colorScheme == .dark ? 0.5 : 0.55)
            }
            .ignoresSafeArea()

            RadialGradient(
                colors: [glowColor, .clear],
                center: .center,
                startRadius: 0,
                endRadius: colorScheme == .dark ? 320 : 420
            )
            .ignoresSafeArea()
        }
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
            : Color(.systemBackground)
    }

    private var gridColor: Color {
        colorScheme == .dark
            ? Color(red: 197 / 255, green: 164 / 255, blue: 85 / 255).opacity(0.035)
            : Color.primary.opacity(0.025)
    }

    private var glowColor: Color {
        colorScheme == .dark
            ? Color(red: 197 / 255, green: 164 / 255, blue: 85 / 255).opacity(0.10)
            : Color.primary.opacity(0.01)
    }
}
