import SwiftUI

// MARK: - CarfaxVaultView

struct CarfaxVaultView: View {
    @StateObject private var carfaxVault = CarfaxVault.shared
    @EnvironmentObject private var supabaseService: SupabaseService
    @State private var invalidReportMessage: String?
    @State private var selectedReportURL: URL?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if carfaxVault.savedReports.isEmpty {
                    ContentUnavailableView(
                        "No Saved Reports",
                        systemImage: "doc.text",
                        description: Text("Purchased Carfax reports saved on this device will appear here.")
                    )
                } else {
                    List(carfaxVault.savedReports) { report in
                        Button {
                            openReport(report)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(displayTitle(for: report))
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text(report.vin)
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(.secondary)

                                    Text("Saved \(dateFormatter.string(from: report.dateSaved))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "safari.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let url = cheapVHRURL(for: report) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Label("Safari", systemImage: "safari")
                                }
                                .tint(.orange)

                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
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

    // MARK: - Helpers

    /// Returns the best available vehicle title, preferring Supabase-decoded
    /// make/model over the original HPD data stored in the report.
    private func displayTitle(for report: SavedReport) -> String {
        let make  = supabaseService.decodedMakeByVIN[report.vin]
                    ?? brandDisplayName(for: report.make)
        let model = supabaseService.decodedModelByVIN[report.vin]
                    ?? report.model
        return "\(report.year) \(make) \(model)"
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
}
