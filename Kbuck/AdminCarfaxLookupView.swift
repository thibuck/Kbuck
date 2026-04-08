import SwiftUI
import Supabase
import UIKit

private struct AdminVINMetadataRow: Decodable {
    let year_make_model: String?
}

private struct AdminDetectedVehicle: Equatable {
    let vin: String
    let year: String
    let make: String
    let model: String
    let version: String

    var displayTitle: String {
        [year, make, model]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var displayVersion: String {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Version pending" : cleaned
    }
}

struct AdminCarfaxLookupView: View {
    @EnvironmentObject private var supabaseService: SupabaseService
    @StateObject private var carfaxVault = CarfaxVault.shared

    @State private var vinInput: String = ""
    @State private var isResolvingVIN = false
    @State private var isFetching = false
    @State private var showFetchConfirmation = false
    @State private var showSavedReportAlert = false
    @State private var errorMessage: String?
    @State private var selectedReportURL: URL?
    @State private var detectedVehicle: AdminDetectedVehicle?
    @State private var lastResolvedVIN: String?
    @State private var lastDecodeSource: String?
    @FocusState private var isVINFieldFocused: Bool

    private var normalizedVINInput: String {
        normalizeVIN(vinInput)
    }

    private var existingReportURL: URL? {
        guard !normalizedVINInput.isEmpty else { return nil }
        return carfaxVault.getReportURL(for: normalizedVINInput)
    }

    private var canRequestCarfax: Bool {
        detectedVehicle?.vin == normalizedVINInput && normalizedVINInput.count == 17 && !isFetching
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.secondarySystemBackground),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        heroCard
                        vinEntryCard
                        detectedVehicleCard

                if let reportURL = existingReportURL {
                    savedReportCard(reportURL: reportURL)
                }
                    }
                    .padding(16)
                    .padding(.bottom, 28)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isVINFieldFocused = false
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                carfaxVault.reloadCatalog()
                Task { await resolveVehicleIfNeeded(force: true) }
            }
            .onChange(of: normalizedVINInput) { _, _ in
                Task { await resolveVehicleIfNeeded() }
            }
            .alert(
                "Confirm Carfax Request",
                isPresented: $showFetchConfirmation,
                presenting: detectedVehicle
            ) { vehicle in
                Button("Cancel", role: .cancel) {}
                Button("Request Report") {
                    Task { await fetchReport(for: vehicle) }
                }
            } message: { vehicle in
                Text("Request Carfax for \(vehicle.displayTitle)?\nVIN: \(vehicle.vin)")
            }
            .alert("Saved Report Found", isPresented: $showSavedReportAlert) {
                if let reportURL = existingReportURL {
                    Button("Open Saved Report") {
                        selectedReportURL = reportURL
                    }
                }
                Button("Request New Report") {
                    showFetchConfirmation = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This VIN already has a saved report.")
            }
            .alert(
                "Carfax Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unable to load the Carfax report.")
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isVINFieldFocused = false
                    }
                }
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VIN Carfax")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Decode first. Request after confirming.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(spacing: 10) {
                if isResolvingVIN {
                    statusPill(title: "Detecting", systemImage: "waveform.path.ecg", tint: .blue)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
        )
    }

    private var vinEntryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "number.square.fill")
                    .foregroundStyle(.secondary)

                TextField("Paste 17-character VIN", text: $vinInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                    .focused($isVINFieldFocused)

                Button {
                    pasteVINFromClipboard()
                } label: {
                    Text("Paste")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)

                if !vinInput.isEmpty {
                    Button {
                        vinInput = ""
                        detectedVehicle = nil
                        lastResolvedVIN = nil
                        lastDecodeSource = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detectedVehicleCard: some View {
        if let detectedVehicle {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Vehicle")
                        .font(.headline)
                    Spacer()
                    if let lastDecodeSource {
                        statusPill(
                            title: lastDecodeSource == "cache" ? "Cache" : "NHTSA",
                            systemImage: lastDecodeSource == "cache" ? "tray.full.fill" : "network",
                            tint: lastDecodeSource == "cache" ? .secondary : .blue
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(detectedVehicle.displayTitle.isEmpty ? "Vehicle identified" : detectedVehicle.displayTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    if !detectedVehicle.displayVersion.isEmpty, detectedVehicle.displayVersion != "Version pending" {
                        Text(detectedVehicle.displayVersion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    isVINFieldFocused = false
                    if existingReportURL != nil {
                        showSavedReportAlert = true
                    } else {
                        showFetchConfirmation = true
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isFetching {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "doc.badge.plus")
                        }
                        Text(isFetching ? "Requesting Carfax..." : "Request Carfax")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [Color.black, Color(red: 0.18, green: 0.22, blue: 0.29)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canRequestCarfax)
                .opacity(canRequestCarfax ? 1 : 0.55)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.blue.opacity(0.12), lineWidth: 1)
            )
        } else if normalizedVINInput.count == 17 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vehicle")
                    .font(.headline)
                if isResolvingVIN {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Decoding VIN...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Waiting for VIN decode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.systemBackground))
            )
        }
    }

    private func savedReportCard(reportURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved Report")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    selectedReportURL = reportURL
                } label: {
                    Label("Open Report", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                ShareLink(item: reportURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
        )
    }

    private func statusPill(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private func resolveVehicleIfNeeded(force: Bool = false) async {
        let vin = normalizedVINInput
        guard vin.count == 17 else {
            await MainActor.run {
                detectedVehicle = nil
                lastResolvedVIN = nil
                lastDecodeSource = nil
            }
            return
        }
        guard force || vin != lastResolvedVIN else { return }
        guard !isResolvingVIN else { return }

        isResolvingVIN = true
        defer { isResolvingVIN = false }

        let resolved = await resolveVehicle(for: vin)
        guard vin == normalizedVINInput else { return }

        await MainActor.run {
            detectedVehicle = resolved
            lastResolvedVIN = vin
        }
    }

    private func fetchReport(for vehicle: AdminDetectedVehicle) async {
        guard !isFetching else { return }

        isFetching = true
        defer { isFetching = false }

        do {
            let result = try await CarfaxReportFetcher.fetchReport(
                requestPayload: CarfaxFetchRequest(
                    vin: vehicle.vin,
                    year: vehicle.year,
                    make: vehicle.make,
                    model: vehicle.model,
                    rawMake: vehicle.make,
                    rawModel: vehicle.model
                ),
                accessToken: supabase.auth.currentSession?.accessToken ?? ""
            )

            carfaxVault.saveReport(
                vin: vehicle.vin,
                html: result.html,
                year: vehicle.year,
                make: vehicle.make,
                model: vehicle.model,
                cheapvhrReportID: result.cheapvhrReportID
            )
            carfaxVault.reloadCatalog()
            selectedReportURL = carfaxVault.getReportURL(for: vehicle.vin)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveVehicle(for vin: String) async -> AdminDetectedVehicle {
        if let decoded = try? await VINDecodeCacheFetcher.decodeAndCache(vin: vin) {
            await supabaseService.loadNHTSACacheForVIN(vin)
            await MainActor.run {
                lastDecodeSource = decoded.source
            }

            let version = [decoded.trim, decoded.engine]
                .map(formatVersionComponent)
                .filter { !$0.isEmpty }
                .joined(separator: " • ")

            return AdminDetectedVehicle(
                vin: decoded.vin,
                year: decoded.year,
                make: decoded.make,
                model: decoded.model,
                version: version
            )
        }

        print("⚠️ VIN DECODE: decode-vin-cache failed or returned no data for \(vin). Falling back to existing cache.")

        await supabaseService.loadNHTSACacheForVIN(vin)

        let cacheRow: AdminVINMetadataRow? = try? await supabase
            .from("global_vin_cache_kbuck")
            .select("year_make_model")
            .eq("vin", value: vin)
            .single()
            .execute()
            .value

        let parsed = parseYearMakeModel(cacheRow?.year_make_model)
        let make = parsed?.make ?? supabaseService.decodedMakeByVIN[vin] ?? ""
        let model = parsed?.model ?? supabaseService.decodedModelByVIN[vin] ?? vin
        let trim = formatVersionComponent(supabaseService.trimByVIN[vin] ?? "")
        let engine = formatVersionComponent(supabaseService.engineByVIN[vin] ?? "")
        let version = [trim, engine].filter { !$0.isEmpty }.joined(separator: " • ")

        print("ℹ️ VIN DECODE FALLBACK: \(vin) -> year=\(parsed?.year ?? "") make=\(make) model=\(model) version=\(version)")

        await MainActor.run {
            lastDecodeSource = make.isEmpty && model == vin ? nil : "cache"
        }

        return AdminDetectedVehicle(
            vin: vin,
            year: parsed?.year ?? "",
            make: make,
            model: model,
            version: version
        )
    }

    private func parseYearMakeModel(_ raw: String?) -> (year: String, make: String, model: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let parts = raw.split(separator: " ").map(String.init)
        let year = parts.first.map(normalizedYear) ?? ""
        let make = parts.dropFirst().first ?? ""
        let model = parts.dropFirst(2).joined(separator: " ")
        return (year, make, model)
    }

    private func pasteVINFromClipboard() {
        let pastedText = UIPasteboard.general.string ?? ""
        let normalized = normalizeVIN(pastedText)
        guard !normalized.isEmpty else { return }

        vinInput = normalized
        isVINFieldFocused = false

        Task {
            await resolveVehicleIfNeeded(force: true)
        }
    }

    private func formatVersionComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lowercased = trimmed.lowercased()
        if lowercased.contains("l"),
           let range = trimmed.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
           let value = Double(trimmed[range]) {
            return String(format: "%.1fL", value)
        }

        return trimmed
    }
}
