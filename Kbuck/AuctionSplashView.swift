import SwiftUI

struct AuctionSplashView: View {
    private let splashDuration: Double = 4.5

    let hpdCount: Int?
    let sheriffCount: Int?

    @State private var starScale: CGFloat = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 16
    @State private var loadingProgress: CGFloat = 0
    @State private var badgeOpacity: Double = 0
    @State private var badgeOffset: CGFloat = 10
    @State private var sourceCardsOpacity: Double = 0
    @State private var sourceCardsOffset: CGFloat = 14
    @State private var glowPulse: Bool = false
    @State private var dotPulse: Bool = false

    let gold = Color(hex: "#C5A455")

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A").ignoresSafeArea()

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

            RadialGradient(
                colors: [gold.opacity(0.10), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 280
            )
            .scaleEffect(glowPulse ? 1.1 : 0.9)
            .animation(
                .easeInOut(duration: splashDuration).repeatForever(autoreverses: true),
                value: glowPulse
            )
            .ignoresSafeArea()

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

            VStack(spacing: 0) {
                LoneStarView(gold: gold)
                    .frame(width: 36, height: 36)
                    .scaleEffect(starScale)
                    .shadow(color: gold.opacity(0.35), radius: 12)
                    .padding(.bottom, 18)

                Text("Houston Auctions")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .kerning(-1.2)
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)

                VStack(spacing: 10) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 156, height: 5)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [gold.opacity(0.75), gold],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 156 * loadingProgress, height: 5)
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    }

                    Text("Loading auction data")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.34))
                        .tracking(0.4)
                }
                .padding(.top, 16)

                if hasAnyCounts {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(gold)
                                .frame(width: 5, height: 5)
                                .scaleEffect(dotPulse ? 1.3 : 0.7)
                                .animation(
                                    .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                                    value: dotPulse
                                )
                            Text("Active auction feeds")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(gold.opacity(0.06))
                        .overlay {
                            Capsule()
                                .strokeBorder(gold.opacity(0.20), lineWidth: 0.5)
                        }
                        .clipShape(Capsule())
                        .opacity(badgeOpacity)
                        .offset(y: badgeOffset)

                        HStack(spacing: 10) {
                            if let hpdCount {
                                sourceListingCard(title: "HPD Auction", count: hpdCount, accent: gold)
                            }
                            if let sheriffCount {
                                sourceListingCard(title: "Sheriff Auction", count: sheriffCount, accent: Color.white.opacity(0.82))
                            }
                        }
                        .frame(maxWidth: 318)
                        .opacity(sourceCardsOpacity)
                        .offset(y: sourceCardsOffset)
                    }
                    .padding(.top, 28)
                }
            }
        }
        .onAppear { animate() }
        .onChange(of: hasAnyCounts) { _, newValue in
            if newValue && badgeOpacity == 0 {
                withAnimation(.interpolatingSpring(stiffness: 100, damping: 16)) {
                    badgeOpacity = 1
                    badgeOffset = 0
                }
                withAnimation(.interpolatingSpring(stiffness: 92, damping: 16).delay(0.12)) {
                    sourceCardsOpacity = 1
                    sourceCardsOffset = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        dotPulse = true
                    }
                }
            }
        }
    }

    private func animate() {
        withAnimation(.easeInOut(duration: splashDuration).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
        withAnimation(.interpolatingSpring(stiffness: 200, damping: 12).delay(0.3)) {
            starScale = 1
        }
        withAnimation(.interpolatingSpring(stiffness: 100, damping: 16).delay(0.55)) {
            titleOpacity = 1
            titleOffset = 0
        }
        withAnimation(.linear(duration: splashDuration - 0.35).delay(0.15)) {
            loadingProgress = 1
        }
        if hasAnyCounts {
            withAnimation(.interpolatingSpring(stiffness: 100, damping: 16).delay(1.3)) {
                badgeOpacity = 1
                badgeOffset = 0
            }
            withAnimation(.interpolatingSpring(stiffness: 92, damping: 16).delay(1.42)) {
                sourceCardsOpacity = 1
                sourceCardsOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            }
        }
    }

    private var hasAnyCounts: Bool {
        hpdCount != nil || sheriffCount != nil
    }

    @ViewBuilder
    private func sourceListingCard(title: String, count: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent.opacity(0.88))
                    .frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.42))
                    .tracking(0.9)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.96))
                    .monospacedDigit()
                Text("listings")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.34))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 0.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

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

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
