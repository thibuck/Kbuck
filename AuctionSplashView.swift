import SwiftUI

struct AuctionSplashView: View {
    
    let totalCount: Int?
    
    @State private var starScale: CGFloat = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 16
    @State private var lineWidth: CGFloat = 0
    @State private var badgeOpacity: Double = 0
    @State private var badgeOffset: CGFloat = 10
    @State private var glowPulse: Bool = false
    @State private var dotPulse: Bool = false

    let gold = Color(hex: "#C5A455")

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A").ignoresSafeArea()

            // Grid
            Canvas { ctx, size in
                let spacing: CGFloat = 36
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
                ctx.stroke(path, with: .color(gold.opacity(0.035)), lineWidth: 0.5)
            }
            .ignoresSafeArea()

            // Radial glow
            RadialGradient(
                colors: [gold.opacity(0.10), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 280
            )
            .scaleEffect(glowPulse ? 1.1 : 0.9)
            .animation(
                .easeInOut(duration: 3).repeatForever(autoreverses: true),
                value: glowPulse
            )
            .ignoresSafeArea()

            // Texas flag strip
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color(red: 0, green: 0.157, blue: 0.408).opacity(0.75)
                    Color(red: 0.749, green: 0.039, blue: 0.188).opacity(0.75)
                    Color.white.opacity(0.45)
                }
                .frame(width: 4)
                Spacer()
            }
            .ignoresSafeArea()

            // Center content
            VStack(spacing: 0) {

                // Lone star
                LoneStarView(gold: gold)
                    .frame(width: 36, height: 36)
                    .scaleEffect(starScale)
                    .shadow(color: gold.opacity(0.35), radius: 12)
                    .padding(.bottom, 18)

                // Title
                Text("HPD Auction")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .kerning(-1.2)
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)

                // Gold line
                Rectangle()
                    .fill(gold)
                    .frame(width: lineWidth, height: 1.5)
                    .cornerRadius(1)
                    .padding(.top, 12)

                // Badge — solo si el dato ya llegó
                if let count = totalCount {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(gold)
                            .frame(width: 5, height: 5)
                            .scaleEffect(dotPulse ? 1.3 : 0.7)
                            .animation(
                                .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                                value: dotPulse
                            )
                        Text("Active listings")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.40))
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(gold.opacity(0.75))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(gold.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(gold.opacity(0.20), lineWidth: 0.5)
                    )
                    .clipShape(Capsule())
                    .opacity(badgeOpacity)
                    .offset(y: badgeOffset)
                    .padding(.top, 28)
                }
            }
        }
        .onAppear { animate() }
        .onChange(of: totalCount) { newCount in
            if newCount != nil && badgeOpacity == 0 {
                withAnimation(.interpolatingSpring(stiffness: 100, damping: 16)) {
                    badgeOpacity = 1
                    badgeOffset = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        dotPulse = true
                    }
                }
            }
        }
    }

    func animate() {
        // Glow idle
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
        // Star
        withAnimation(.interpolatingSpring(stiffness: 200, damping: 12).delay(0.3)) {
            starScale = 1
        }
        // Title
        withAnimation(.interpolatingSpring(stiffness: 100, damping: 16).delay(0.55)) {
            titleOpacity = 1
            titleOffset = 0
        }
        // Gold line
        withAnimation(.interpolatingSpring(stiffness: 120, damping: 18).delay(1.0)) {
            lineWidth = 36
        }
        // Badge — solo anima si el dato ya estaba disponible al aparecer
        if totalCount != nil {
            withAnimation(.interpolatingSpring(stiffness: 100, damping: 16).delay(1.3)) {
                badgeOpacity = 1
                badgeOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            }
        }
    }
}

// MARK: - Lone Star

struct LoneStarView: View {
    let gold: Color
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let outer = min(size.width, size.height) / 2
            let inner = outer * 0.42
            var path = Path()
            for i in 0..<10 {
                let angle = Double(i) * .pi / 5 - .pi / 2
                let r = i.isMultiple(of: 2) ? outer : inner
                let pt = CGPoint(
                    x: cx + CGFloat(cos(angle)) * r,
                    y: cy + CGFloat(sin(angle)) * r
                )
                i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(gold.opacity(0.12)))
            ctx.stroke(path, with: .color(gold.opacity(0.85)), lineWidth: 1.2)
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
