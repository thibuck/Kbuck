import Foundation
import Combine
import Supabase

struct SavedReport: Identifiable, Codable, Hashable {
    let id: UUID
    let vin: String
    let year: String
    let make: String
    let model: String
    let fileName: String
    let cheapvhrReportID: String?
    let dateSaved: Date

    var fileURL: URL {
        CarfaxVault.reportFileURL(for: fileName)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case vin
        case year
        case make
        case model
        case fileName
        case fileURL
        case cheapvhrReportID = "cheapvhr_report_id"
        case dateSaved
    }

    init(
        id: UUID,
        vin: String,
        year: String,
        make: String,
        model: String,
        fileName: String,
        cheapvhrReportID: String?,
        dateSaved: Date
    ) {
        self.id = id
        self.vin = vin
        self.year = year
        self.make = make
        self.model = model
        self.fileName = fileName
        self.cheapvhrReportID = cheapvhrReportID
        self.dateSaved = dateSaved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vin = try container.decode(String.self, forKey: .vin)
        year = try container.decode(String.self, forKey: .year)
        make = try container.decode(String.self, forKey: .make)
        model = try container.decode(String.self, forKey: .model)
        dateSaved = try container.decode(Date.self, forKey: .dateSaved)
        cheapvhrReportID = try container.decodeIfPresent(String.self, forKey: .cheapvhrReportID)

        if let fileName = try container.decodeIfPresent(String.self, forKey: .fileName) {
            self.fileName = fileName
        } else if let legacyURL = try container.decodeIfPresent(URL.self, forKey: .fileURL) {
            self.fileName = legacyURL.lastPathComponent
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileName,
                in: container,
                debugDescription: "Missing file reference for saved report."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(vin, forKey: .vin)
        try container.encode(year, forKey: .year)
        try container.encode(make, forKey: .make)
        try container.encode(model, forKey: .model)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(cheapvhrReportID, forKey: .cheapvhrReportID)
        try container.encode(dateSaved, forKey: .dateSaved)
    }
}

private struct CarfaxRequestLogRow: Decodable {
    let vin: String
    let created_at: String?
}

private struct GlobalVINCacheRow: Decodable {
    let vin: String
    let cheapvhr_report_id: String?
    let year_make_model: String?
    let last_fetched_at: String?
}

@MainActor
final class CarfaxVault: ObservableObject {
    static let shared = CarfaxVault()

    @Published private(set) var savedReports: [SavedReport] = []

    private let catalogKey = "carfaxVaultCatalog"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        loadCatalog()
        Task { await syncReportsFromSupabase() }
    }

    func reloadCatalog() {
        loadCatalog()
        Task { await syncReportsFromSupabase() }
    }

    func saveReport(
        vin: String,
        html: String,
        year: String,
        make: String,
        model: String,
        cheapvhrReportID: String?
    ) {
        let cleanVIN = normalizeVIN(vin)
        let cleanReportID = cheapvhrReportID?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanVIN.isEmpty else { return }

        do {
            let reportsDirectory = try reportsFolderURL()
            let fileName = fileName(for: cleanVIN, year: year, make: make, model: model)
            let fileURL = reportsDirectory.appendingPathComponent(fileName)

            try html.write(to: fileURL, atomically: true, encoding: .utf8)

            let report = SavedReport(
                id: UUID(),
                vin: cleanVIN,
                year: normalizedYear(year),
                make: make,
                model: model,
                fileName: fileName,
                cheapvhrReportID: cleanReportID?.isEmpty == false ? cleanReportID : nil,
                dateSaved: Date()
            )

            savedReports.removeAll { normalizeVIN($0.vin) == cleanVIN }
            savedReports.insert(report, at: 0)
            persistCatalog()
            Task { await syncReportsFromSupabase(vins: [cleanVIN]) }
        } catch {
            return
        }
    }

    func getReportURL(for vin: String) -> URL? {
        let cleanVIN = normalizeVIN(vin)
        guard let report = savedReports.first(where: { normalizeVIN($0.vin) == cleanVIN }) else { return nil }
        return cheapVHRURL(for: report)
    }

    func cheapVHRURL(for report: SavedReport) -> URL? {
        let reportID = report.cheapvhrReportID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reportID.isEmpty else { return nil }
        return URL(string: "https://cheapvhr.com/dashboard/report/carfax/\(reportID)/raw")
    }

    private func loadCatalog() {
        guard let data = UserDefaults.standard.data(forKey: catalogKey) else { return }

        do {
            let decoded = try decoder.decode([SavedReport].self, from: data)
            savedReports = decoded
                .filter {
                    FileManager.default.fileExists(atPath: $0.fileURL.path) ||
                    (($0.cheapvhrReportID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false)
                }
                .sorted { $0.dateSaved > $1.dateSaved }
        } catch {
            savedReports = []
        }
    }

    private func persistCatalog() {
        guard let data = try? encoder.encode(savedReports) else { return }
        UserDefaults.standard.set(data, forKey: catalogKey)
    }

    private func syncReportsFromSupabase(vins requestedVINs: [String]? = nil) async {
        guard let userID = supabase.auth.currentUser?.id else { return }

        let targetVINs = requestedVINs?.map(normalizeVIN).filter { !$0.isEmpty } ?? savedReports.map(\.vin)

        do {
            let vinsToResolve: [String]
            let logDatesByVIN: [String: Date]

            if targetVINs.isEmpty {
                let logRows: [CarfaxRequestLogRow] = try await supabase
                    .from("carfax_request_log_kbuck")
                    .select("vin, created_at")
                    .eq("user_id", value: userID.uuidString)
                    .eq("status", value: "served")
                    .order("created_at", ascending: false)
                    .execute()
                    .value

                vinsToResolve = uniqueVINsPreservingOrder(logRows.map(\.vin))
                logDatesByVIN = Dictionary(
                    uniqueKeysWithValues: logRows.compactMap { row in
                        guard let date = parseSupabaseDate(row.created_at) else { return nil }
                        return (normalizeVIN(row.vin), date)
                    }
                )
            } else {
                vinsToResolve = uniqueVINsPreservingOrder(targetVINs)
                logDatesByVIN = [:]
            }

            guard !vinsToResolve.isEmpty else { return }

            let cacheRows: [GlobalVINCacheRow] = try await supabase
                .from("global_vin_cache_kbuck")
                .select("vin, cheapvhr_report_id, year_make_model, last_fetched_at")
                .in("vin", values: vinsToResolve)
                .execute()
                .value

            let cacheByVIN = Dictionary(uniqueKeysWithValues: cacheRows.map { (normalizeVIN($0.vin), $0) })
            var mergedByVIN = Dictionary(uniqueKeysWithValues: savedReports.map { (normalizeVIN($0.vin), $0) })

            for vin in vinsToResolve {
                let cleanVIN = normalizeVIN(vin)
                guard let cache = cacheByVIN[cleanVIN] else { continue }
                guard let reportID = cache.cheapvhr_report_id?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reportID.isEmpty else { continue }

                if let existing = mergedByVIN[cleanVIN] {
                    mergedByVIN[cleanVIN] = SavedReport(
                        id: existing.id,
                        vin: existing.vin,
                        year: existing.year,
                        make: existing.make,
                        model: existing.model,
                        fileName: existing.fileName,
                        cheapvhrReportID: reportID,
                        dateSaved: existing.dateSaved
                    )
                    continue
                }

                let metadata = parseYearMakeModel(cache.year_make_model, vin: cleanVIN)
                let fileName = fileName(for: cleanVIN, year: metadata.year, make: metadata.make, model: metadata.model)
                mergedByVIN[cleanVIN] = SavedReport(
                    id: UUID(),
                    vin: cleanVIN,
                    year: metadata.year,
                    make: metadata.make,
                    model: metadata.model,
                    fileName: fileName,
                    cheapvhrReportID: reportID,
                    dateSaved: logDatesByVIN[cleanVIN] ?? parseSupabaseDate(cache.last_fetched_at) ?? Date()
                )
            }

            savedReports = Array(mergedByVIN.values).sorted { $0.dateSaved > $1.dateSaved }
            persistCatalog()
        } catch {
            return
        }
    }

    private func reportsFolderURL() throws -> URL {
        let folderURL = Self.reportsFolderURL()

        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        return folderURL
    }

    static func reportsFolderURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documentsURL.appendingPathComponent("CarfaxVault", isDirectory: true)
    }

    static func reportFileURL(for fileName: String) -> URL {
        reportsFolderURL().appendingPathComponent(fileName)
    }

    private func fileName(for vin: String, year: String, make: String, model: String) -> String {
        let parts = [
            normalizedYear(year),
            sanitizedComponent(make),
            sanitizedComponent(model),
            vin
        ]
        .filter { !$0.isEmpty }

        return parts.joined(separator: "_") + ".html"
    }

    private func sanitizedComponent(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func uniqueVINsPreservingOrder(_ vins: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for vin in vins {
            let cleanVIN = normalizeVIN(vin)
            guard !cleanVIN.isEmpty, !seen.contains(cleanVIN) else { continue }
            seen.insert(cleanVIN)
            ordered.append(cleanVIN)
        }

        return ordered
    }

    private func parseYearMakeModel(_ raw: String?, vin: String) -> (year: String, make: String, model: String) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ("", "", vin)
        }

        let parts = raw.split(separator: " ").map(String.init)
        let year = parts.first.map(normalizedYear) ?? ""
        let make = parts.dropFirst().first ?? ""
        let model = parts.dropFirst(2).joined(separator: " ")
        return (year, make, model.isEmpty ? vin : model)
    }

    private func parseSupabaseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: raw) { return date }

        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        if let date = isoBasic.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }

        return nil
    }
}
