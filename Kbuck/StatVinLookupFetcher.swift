import Foundation

struct StatVinLookupResult: Sendable {
    let status: StatVinLookupStatus
    let resolvedURL: URL
}

enum StatVinLookupFetcher {
    private static let timeoutInterval: TimeInterval = 20

    static func resolve(vin: String) async throws -> StatVinLookupResult {
        let cleanVIN = normalizeVIN(vin)
        guard cleanVIN.count == 17 else {
            throw StatVinLookupError.invalidVIN
        }

        guard let url = URL(string: "https://stat.vin/cars/\(cleanVIN)") else {
            throw StatVinLookupError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = response.url else {
            throw StatVinLookupError.missingFinalURL
        }

        let status = classify(finalURL: finalURL)
        print("✅ STAT.VIN LOOKUP: \(cleanVIN) -> \(status.rawValue) @ \(finalURL.absoluteString)")
        return StatVinLookupResult(status: status, resolvedURL: finalURL)
    }

    private static func classify(finalURL: URL) -> StatVinLookupStatus {
        let lowercasedURL = finalURL.absoluteString.lowercased()
        if lowercasedURL.contains("stat.vin/vin-decoding/") {
            return .noHistory
        }
        if lowercasedURL.contains("stat.vin/cars/") {
            return .hasHistory
        }
        return .unknown
    }
}

enum StatVinLookupError: LocalizedError {
    case invalidVIN
    case invalidURL
    case missingFinalURL

    var errorDescription: String? {
        switch self {
        case .invalidVIN:
            return "Invalid VIN for stat.vin lookup."
        case .invalidURL:
            return "Invalid stat.vin URL."
        case .missingFinalURL:
            return "Unable to resolve the final stat.vin URL."
        }
    }
}
