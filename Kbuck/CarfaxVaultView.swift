import SwiftUI

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

// MARK: - CarfaxVaultView

struct CarfaxVaultView: View {
    @StateObject private var carfaxVault = CarfaxVault.shared
    @EnvironmentObject private var supabaseService: SupabaseService
    @Environment(\.colorScheme) private var colorScheme
    @State private var invalidReportMessage: String?
    @State private var selectedReportURL: URL?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var reportCardBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.74)
    }

    private var reportCardBorder: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var recentReport: SavedReport? {
        carfaxVault.savedReports.sorted { $0.dateSaved > $1.dateSaved }.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppChromeBackground()
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        reportsHero

                        if carfaxVault.savedReports.isEmpty {
                            ContentUnavailableView(
                                "No Saved Reports",
                                systemImage: "archivebox",
                                description: Text("Purchased Carfax reports saved on this device will appear here.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(carfaxVault.savedReports) { report in
                                    reportCard(for: report)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .background(Color.clear)
                .navigationTitle("My Reports")
                .onAppear {
                    carfaxVault.reloadCatalog()
                    Task {
                        for report in carfaxVault.savedReports {
                            await supabaseService.loadNHTSACacheForVIN(report.vin)
                        }
                    }
                }
                .alert(
                    "Report Unavailable",
                    isPresented: Binding(
                        get: { invalidReportMessage != nil },
                        set: { if !$0 { invalidReportMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(invalidReportMessage ?? "")
                }
                .sheet(isPresented: Binding(
                    get: { selectedReportURL != nil },
                    set: { if !$0 { selectedReportURL = nil } }
                )) {
                    if let url = selectedReportURL {
                        NavigationStack {
                            SafariControllerView(url: url)
                                .ignoresSafeArea()
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button {
                                            UIApplication.shared.open(url)
                                        } label: {
                                            Image(systemName: "safari")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Returns the best available vehicle title, preferring Supabase-decoded
    /// make/model over the original HPD data stored in the report.
    private func displayTitle(for report: SavedReport) -> String {
        let cleanVIN = normalizeVIN(report.vin)
        let make = supabaseService.decodedMakeByVIN[cleanVIN]
            ?? brandDisplayName(for: report.make)
        let model = supabaseService.decodedModelByVIN[cleanVIN]
            ?? normalizedModelName(for: report.model, make: report.make)
        return "\(normalizedYear(report.year)) \(make) \(model)"
    }

    private func cheapVHRURL(for report: SavedReport) -> URL? {
        carfaxVault.cheapVHRURL(for: report)
    }

    private func openReport(_ report: SavedReport) {
        guard let url = cheapVHRURL(for: report) else {
            invalidReportMessage = "Could not construct a valid report URL for VIN \(report.vin)."
            return
        }
        selectedReportURL = url
    }

    private var reportsHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT VAULT")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(Color.primary.opacity(0.34))

                    Text("Saved vehicle reports")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.92))

                    Text("Open, share, or jump into Safari without digging through a plain list.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "archivebox.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: "#C5A455"))
                    .padding(14)
                    .background(Color(hex: "#C5A455").opacity(colorScheme == .dark ? 0.12 : 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(spacing: 10) {
                metricPill(title: "Reports", value: "\(carfaxVault.savedReports.count)")
                metricPill(title: "Latest", value: recentReport.map { shortDate($0.dateSaved) } ?? "—")
            }
        }
        .padding(18)
        .background(reportCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(reportCardBorder, lineWidth: 0.5)
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.primary.opacity(0.34))

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reportCard(for report: SavedReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle(for: report))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(report.vin)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.42))

                    Text("Saved \(dateFormatter.string(from: report.dateSaved))")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.52))
                }

                Spacer(minLength: 0)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "#C5A455"))
            }

            HStack(spacing: 10) {
                quickActionButton(title: "Open", icon: "play.fill", filled: true) {
                    openReport(report)
                }

                if let url = cheapVHRURL(for: report) {
                    quickActionButton(title: "Safari", icon: "safari", filled: false) {
                        UIApplication.shared.open(url)
                    }

                    ShareLink(item: url) {
                        quickActionButtonLabel(title: "Share", icon: "square.and.arrow.up", filled: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(reportCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(reportCardBorder, lineWidth: 0.5)
        }
    }

    private func quickActionButton(title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickActionButtonLabel(title: title, icon: icon, filled: filled)
        }
        .buttonStyle(.plain)
    }

    private func quickActionButtonLabel(title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(filled ? Color.black.opacity(0.82) : Color.primary.opacity(0.78))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            filled
                ? Color(hex: "#C5A455")
                : Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
