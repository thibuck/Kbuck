import Foundation

struct SheriffAuctionFetcher {
    private let baseURL = URL(string: "https://www.govtowauction.com")!
    private let authToken = "1494175a-a628-4c94-a442-c7f2f005fc4e"
    private let enterpriseID = 10
    private let pageSize = 100

    func fetchAllEntries() async throws -> [HPDEntry] {
        let lots = try await fetchStorageLots()
        var allEntries: [HPDEntry] = []

        for lot in lots {
            if let upcomingEntries = try? await fetchUpcomingVehicles(storageLotID: lot.storageLotId) {
                allEntries.append(contentsOf: upcomingEntries)
            }

            // `Current Auctions` uses a different selection flow on GovTow. We
            // can derive active AuctionDateIds from the count endpoint and then
            // best-effort query the same vehicle feed in current mode. If the
            // backend returns no rows for that lot/date, we simply keep the
            // working upcoming feed and move on.
            if let currentEntries = try? await fetchCurrentVehicles(
                storageLotID: lot.storageLotId,
                storageLotGuidID: lot.guidID
            ) {
                allEntries.append(contentsOf: currentEntries)
            }
        }

        return mergedAuctionEntries(allEntries)
    }

    private func fetchStorageLots() async throws -> [StorageLot] {
        let request = try makeRequest(path: "/API/enterprise/GetEnterpriseStorageLots?enterpriseId=\(enterpriseID)&userName=")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([StorageLot].self, from: data)
    }

    private func fetchUpcomingVehicles(storageLotID: Int) async throws -> [HPDEntry] {
        let firstPage = try await fetchVehiclePage(storageLotID: storageLotID, page: 1)
        let totalPages = max(firstPage.first?.totalPages ?? 1, 1)
        var allVehicles = firstPage

        if totalPages > 1 {
            for page in 2...totalPages {
                let pageVehicles = try await fetchVehiclePage(storageLotID: storageLotID, page: page)
                allVehicles.append(contentsOf: pageVehicles)
            }
        }

        return allVehicles.compactMap { vehicle in
            guard let date = normalizedSheriffDate(from: vehicle.startDate) else { return nil }

            return HPDEntry(
                dateScheduled: date,
                time: compactSheriffTime(from: vehicle.startDate),
                lotName: vehicle.storageLocationName.trimmingCharacters(in: .whitespacesAndNewlines),
                lotAddress: vehicle.storageLocationAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                year: vehicle.year.trimmingCharacters(in: .whitespacesAndNewlines),
                make: vehicle.make.trimmingCharacters(in: .whitespacesAndNewlines),
                model: vehicle.model.trimmingCharacters(in: .whitespacesAndNewlines),
                vin: vehicle.vin.trimmingCharacters(in: .whitespacesAndNewlines),
                plate: (vehicle.licensePlate ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                source: .sheriffAuction
            )
        }
    }

    private func fetchCurrentVehicles(storageLotID: Int, storageLotGuidID: String) async throws -> [HPDEntry] {
        let auctionDateIDs = try await fetchCurrentAuctionDateIDs(storageLotGuidID: storageLotGuidID)
        guard !auctionDateIDs.isEmpty else { return [] }

        var entries: [HPDEntry] = []
        for auctionDateID in auctionDateIDs {
            let pageVehicles = try await fetchVehiclePage(
                storageLotID: storageLotID,
                page: 1,
                auctionDateID: auctionDateID,
                isCurrentAuction: true
            )

            let mapped = pageVehicles.compactMap { vehicle -> HPDEntry? in
                guard let date = normalizedSheriffDate(from: vehicle.startDate) else { return nil }

                return HPDEntry(
                    dateScheduled: date,
                    time: compactSheriffTime(from: vehicle.startDate),
                    lotName: vehicle.storageLocationName.trimmingCharacters(in: .whitespacesAndNewlines),
                    lotAddress: vehicle.storageLocationAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                    year: vehicle.year.trimmingCharacters(in: .whitespacesAndNewlines),
                    make: vehicle.make.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: vehicle.model.trimmingCharacters(in: .whitespacesAndNewlines),
                    vin: vehicle.vin.trimmingCharacters(in: .whitespacesAndNewlines),
                    plate: (vehicle.licensePlate ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    source: .sheriffAuction
                )
            }

            entries.append(contentsOf: mapped)
        }

        return entries
    }

    private func fetchCurrentAuctionDateIDs(storageLotGuidID: String) async throws -> [Int] {
        let path = "/API/app/auctionWeb/CheckViewCount?productId=&enterpriseId=\(enterpriseID)&storageLotGuidId=\(storageLotGuidID)&dateId=&isCurrent=1&isUpcoming=&typeList=1"
        let request = try makeRequest(path: path)
        let (data, _) = try await URLSession.shared.data(for: request)
        let counters = try JSONDecoder().decode([SheriffAuctionCounter].self, from: data)
        return counters
            .filter { $0.counterValue > 0 }
            .map(\.auctionDateID)
    }

    private func fetchVehiclePage(
        storageLotID: Int,
        page: Int,
        auctionDateID: Int? = nil,
        isCurrentAuction: Bool = false
    ) async throws -> [SheriffVehicle] {
        let auctionDateParam = auctionDateID.map(String.init) ?? "undefined"
        let currentFlag = isCurrentAuction ? "true" : "false"
        let path = "/API/vehicle/GetLatestVehicles?pageNum=\(page)&pageSize=\(pageSize)&enterpriseId=\(enterpriseID)&storageLotId=\(storageLotID)&recordId=undefined&bidderId=&makeId=undefined&modelId=undefined&styleId=undefined&fromYear=undefined&toYear=undefined&auctionDateId=\(auctionDateParam)&colorId=undefined&isCurrentAuction=\(currentFlag)"
        let request = try makeRequest(path: path)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([SheriffVehicle].self, from: data)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func normalizedSheriffDate(from isoString: String) -> String? {
        guard let date = sheriffDate(from: isoString) else { return nil }
        return sheriffDisplayDateFormatter.string(from: date)
    }

    private func compactSheriffTime(from isoString: String) -> String? {
        guard let date = sheriffDate(from: isoString) else { return nil }
        return date.compactAuctionTime()
    }

    private func sheriffDate(from isoString: String) -> Date? {
        if let date = sheriffISOFormatter.date(from: isoString) {
            return date
        }
        return sheriffFallbackFormatter.date(from: isoString)
    }
}

private struct StorageLot: Decodable {
    let storageLotId: Int
    let guidID: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageLotId = container.decodeFlexibleInt(forKey: .storageLotId) ?? 0
        guidID = container.decodeFlexibleString(forKey: .guidID) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case storageLotId = "StorageLotId"
        case guidID = "GuidID"
    }
}

private struct SheriffAuctionCounter: Decodable {
    let auctionDateID: Int
    let counterValue: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        auctionDateID = container.decodeFlexibleInt(forKey: .auctionDateID) ?? 0
        counterValue = container.decodeFlexibleInt(forKey: .counterValue) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case auctionDateID = "AuctionDateId"
        case counterValue = "CounterValue"
    }
}

private struct SheriffVehicle: Decodable {
    let totalPages: Int?
    let make: String
    let model: String
    let year: String
    let vin: String
    let licensePlate: String?
    let startDate: String
    let storageLocationName: String
    let storageLocationAddress: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalPages = container.decodeFlexibleInt(forKey: .totalPages)
        make = container.decodeFlexibleString(forKey: .make) ?? ""
        model = container.decodeFlexibleString(forKey: .model) ?? ""
        year = container.decodeFlexibleString(forKey: .year) ?? ""
        vin = container.decodeFlexibleString(forKey: .vin) ?? ""
        licensePlate = container.decodeFlexibleString(forKey: .licensePlate)
        startDate = container.decodeFlexibleString(forKey: .startDate) ?? ""
        storageLocationName = container.decodeFlexibleString(forKey: .storageLocationName) ?? ""
        storageLocationAddress = container.decodeFlexibleString(forKey: .storageLocationAddress) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case totalPages = "TotalPages"
        case make = "Make"
        case model = "Model"
        case year = "Year"
        case vin = "VIN"
        case licensePlate = "LicensePlate"
        case startDate = "StartDate"
        case storageLocationName = "StorageLocationName"
        case storageLocationAddress = "StorageLocationAddress"
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return String(Int(value))
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

private let sheriffISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let sheriffFallbackFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

private let sheriffDisplayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MM/dd/yyyy"
    return formatter
}()
