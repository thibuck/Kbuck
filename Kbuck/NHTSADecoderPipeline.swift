import Foundation
import Supabase

extension Notification.Name {
    static let nhtsaCacheDidUpdate = Notification.Name("nhtsaCacheDidUpdate")
}

struct NHTSADecodeResponse: Decodable, Sendable {
    let results: [NHTSAVariableResult]

    enum CodingKeys: String, CodingKey {
        case results = "Results"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.results = try container.decode([NHTSAVariableResult].self, forKey: .results)
    }

    nonisolated func value(for variableName: String) -> String? {
        let normalizedName = variableName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return results.first { result in
            result.variable.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }?.cleanValue
    }

    nonisolated func extractedVehicleData() -> NHTSADecodedVehicleData {
        let rawMake = value(for: "Make")
        let rawModel = value(for: "Model")

        let cleanedMake = rawMake.map { NHTSACleaner.cleanMake($0) }
        let cleanedModel: String?
        if let rawMake, let rawModel {
            cleanedModel = NHTSACleaner.cleanModel(rawModel, make: rawMake)
        } else {
            cleanedModel = rawModel?.capitalized
        }

        return NHTSADecodedVehicleData(
            year: value(for: "Model Year").flatMap { NHTSACleaner.cleanYear($0) },
            make: cleanedMake,
            model: cleanedModel,
            engineDisplacementL: value(for: "Displacement (L)"),
            engineCylinders: value(for: "Engine Number of Cylinders"),
            driveType: value(for: "Drive Type")?.capitalized
        )
    }
}

struct NHTSAVariableResult: Decodable, Sendable {
    let variable: String
    let value: String?

    enum CodingKeys: String, CodingKey {
        case variable = "Variable"
        case value = "Value"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.variable = try container.decode(String.self, forKey: .variable)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
    }

    nonisolated var cleanValue: String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let normalized = trimmedValue.lowercased()
        if normalized == "null" || normalized == "n/a" || normalized == "not applicable" {
            return nil
        }

        return trimmedValue
    }
}

struct NHTSADecodedVehicleData: Sendable {
    let year: Int?
    let make: String?
    let model: String?
    let engineDisplacementL: String?
    let engineCylinders: String?
    let driveType: String?
}

struct NHTSAScrapedVehicle: Sendable {
    let vin: String
    let auctionLotID: String?
    let auctionPrice: Double?

    nonisolated init(vin: String, auctionLotID: String? = nil, auctionPrice: Double? = nil) {
        self.vin = vin
        self.auctionLotID = auctionLotID
        self.auctionPrice = auctionPrice
    }
}

struct NHTSACacheUpdate: Codable, Sendable {
    let vin: String
    let year: Int?
    let make: String?
    let model: String?
    let engine_cylinders: String?
    let engine_displacement_l: String?
    let drive_type: String?
    let auction_lot_id: String?
    let auction_price: Double?
    let trim: String?
    let body_class: String?
    let city_mpg: String?
    let hwy_mpg: String?

    var displayTrim: String { displayValue(for: trim) }
    var displayBodyClass: String { displayValue(for: body_class) }
    var displayCityMpg: String { displayValue(for: city_mpg) }
    var displayHwyMpg: String { displayValue(for: hwy_mpg) }

    private func displayValue(for value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "-"
        }
        return trimmed
    }

    nonisolated init(
        vin: String,
        year: Int? = nil,
        make: String? = nil,
        model: String? = nil,
        engineCylinders: String? = nil,
        engineDisplacementL: String? = nil,
        driveType: String? = nil,
        auctionLotID: String? = nil,
        auctionPrice: Double? = nil,
        trim: String? = nil,
        bodyClass: String? = nil,
        cityMpg: String? = nil,
        hwyMpg: String? = nil
    ) {
        self.vin = vin
        self.year = year
        self.make = make
        self.model = model
        self.engine_cylinders = engineCylinders?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.engine_displacement_l = engineDisplacementL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.drive_type = driveType?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auction_lot_id = auctionLotID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auction_price = auctionPrice
        self.trim = trim?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body_class = bodyClass?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.city_mpg = cityMpg?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hwy_mpg = hwyMpg?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vin, forKey: .vin)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(make, forKey: .make)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(engine_cylinders, forKey: .engine_cylinders)
        try container.encodeIfPresent(engine_displacement_l, forKey: .engine_displacement_l)
        try container.encodeIfPresent(drive_type, forKey: .drive_type)
        try container.encodeIfPresent(auction_lot_id, forKey: .auction_lot_id)
        try container.encodeIfPresent(auction_price, forKey: .auction_price)
        try container.encodeIfPresent(trim, forKey: .trim)
        try container.encodeIfPresent(body_class, forKey: .body_class)
        try container.encodeIfPresent(city_mpg, forKey: .city_mpg)
        try container.encodeIfPresent(hwy_mpg, forKey: .hwy_mpg)
    }
}

actor NHTSADecoderPipeline {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let requestDelayNanoseconds: UInt64

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        requestDelayNanoseconds: UInt64 = 1_500_000_000
    ) {
        self.session = session
        self.decoder = decoder
        self.requestDelayNanoseconds = requestDelayNanoseconds
    }

    func decodeAndCache(
        _ vehicles: [NHTSAScrapedVehicle],
        onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil
    ) async {
        let cleanedVehicles = vehicles.compactMap { vehicle -> NHTSAScrapedVehicle? in
            let vin = NHTSACleaner.normalizeVIN(vehicle.vin)
            guard vin.count == 17 else { return nil }

            return NHTSAScrapedVehicle(
                vin: vin,
                auctionLotID: vehicle.auctionLotID,
                auctionPrice: vehicle.auctionPrice
            )
        }

        print("🚀 NHTSA PIPELINE: starting batch. Received \(vehicles.count) vehicles, \(cleanedVehicles.count) valid VINs.")
        await onProgress?(0, cleanedVehicles.count)

        for (index, vehicle) in cleanedVehicles.enumerated() {
            let current = index + 1
            print("🔎 NHTSA PIPELINE: [\(current)/\(cleanedVehicles.count)] querying VIN \(vehicle.vin)")

            do {
                let decoded = try await fetchDecodedVehicle(for: vehicle.vin)
                let update = NHTSACacheUpdate(
                    vin: vehicle.vin,
                    year: decoded.year,
                    make: decoded.make,
                    model: decoded.model,
                    engineCylinders: decoded.engineCylinders,
                    engineDisplacementL: decoded.engineDisplacementL,
                    driveType: decoded.driveType,
                    auctionLotID: vehicle.auctionLotID,
                    auctionPrice: vehicle.auctionPrice
                )

                try await upsertCacheUpdate(update)
                print("✅ NHTSA PIPELINE: [\(current)/\(cleanedVehicles.count)] upsert succeeded for VIN \(vehicle.vin)")
            } catch {
                print("🔴 NHTSA PIPELINE: failed for VIN \(vehicle.vin): \(error)")
            }

            await onProgress?(current, cleanedVehicles.count)

            if index < cleanedVehicles.count - 1 {
                print("⏱️ NHTSA PIPELINE: sleeping 1.5s before next VIN")
                try? await Task.sleep(nanoseconds: requestDelayNanoseconds)
            }
        }

        print("🏁 NHTSA PIPELINE: batch finished. Processed \(cleanedVehicles.count) VINs.")
    }

    private func fetchDecodedVehicle(for vin: String) async throws -> NHTSADecodedVehicleData {
        guard let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/\(vin)?format=json") else {
            throw PipelineError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PipelineError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            throw PipelineError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PipelineError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let payload = try decoder.decode(NHTSADecodeResponse.self, from: data)
        return payload.extractedVehicleData()
    }

    private func upsertCacheUpdate(_ update: NHTSACacheUpdate) async throws {
        print("📤 NHTSA PIPELINE: upserting VIN \(update.vin) to global_vin_cache_kbuck")
        try await supabase
            .from("global_vin_cache_kbuck")
            .upsert(update, onConflict: "vin")
            .execute()

        await MainActor.run {
            NotificationCenter.default.post(name: .nhtsaCacheDidUpdate, object: update)
        }
    }
}

extension NHTSADecoderPipeline {
    enum PipelineError: Error {
        case invalidURL
        case invalidResponse
        case rateLimited
        case requestFailed(statusCode: Int)
    }
}

private enum NHTSACleaner {
    nonisolated static func normalizeVIN(_ rawVIN: String) -> String {
        let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        return rawVIN.uppercased().filter { allowed.contains($0) }
    }

    nonisolated static func cleanYear(_ rawYear: String) -> Int? {
        let trimmedYear = rawYear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = Int(trimmedYear) else {
            return nil
        }

        if trimmedYear.count == 2 {
            return year <= 24 ? 2000 + year : 1900 + year
        }

        return year
    }

    nonisolated static func cleanMake(_ rawMake: String) -> String {
        rawMake
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    nonisolated static func cleanModel(_ rawModel: String, make _: String) -> String {
        rawModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .map { token in
                let uppercasedToken = token.uppercased()
                if uppercasedToken == "CRV" { return "CR-V" }
                if uppercasedToken == "RAV4" { return "RAV4" }
                if uppercasedToken == "F150" { return "F-150" }
                return token.capitalized
            }
            .joined(separator: " ")
    }

    nonisolated static func cleanAuctionPrice(_ rawPrice: String) -> Double? {
        let cleanedPrice = rawPrice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)

        guard !cleanedPrice.isEmpty else { return nil }
        return Double(cleanedPrice)
    }
}
