import SwiftUI

// MARK: - CarfaxVaultView

struct CarfaxVaultView: View {
    @StateObject private var carfaxVault = CarfaxVault.shared
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
                                    Text("\(report.year) \(brandDisplayName(for: report.make)) \(report.model)")
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
            .onAppear { carfaxVault.reloadCatalog() }
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
