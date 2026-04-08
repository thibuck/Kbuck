import Foundation

struct CarfaxFetchRequest {
    let vin: String
    let year: String
    let make: String
    let model: String
    let rawMake: String
    let rawModel: String
}

struct CarfaxFetchResult {
    let html: String
    let cheapvhrReportID: String?
}

enum CarfaxReportFetcher {
    private static let edgeFunctionURLString = "https://tnescuqegmehazuffmte.supabase.co/functions/v1/fetch-vhr"
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRuZXNjdXFlZ21laGF6dWZmbXRlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2OTI4ODEsImV4cCI6MjA4OTI2ODg4MX0.LszstZi962himWPuoSWEXR9Xzhbl2ncewJSGzTnoeIg"

    static func fetchReport(
        requestPayload: CarfaxFetchRequest,
        accessToken: String
    ) async throws -> CarfaxFetchResult {
        guard let url = URL(string: edgeFunctionURLString) else {
            throw CarfaxFetchError.invalidURL
        }

        let payload: [String: String] = [
            "vin": requestPayload.vin,
            "year": requestPayload.year,
            "make": requestPayload.make,
            "model": requestPayload.model,
            "raw_make": requestPayload.rawMake,
            "raw_model": requestPayload.rawModel
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CarfaxFetchError.serverError(
                statusCode: httpResponse.statusCode,
                message: body?.isEmpty == false ? body : nil
            )
        }

        guard let html = extractCarfaxHTML(from: data) else {
            throw CarfaxFetchError.missingHTML
        }

        return CarfaxFetchResult(
            html: html,
            cheapvhrReportID: extractCheapVHRReportID(from: data)
        )
    }

    private static func extractCheapVHRReportID(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let candidateKeys = ["cheapvhr_report_id", "cheapvhrReportID", "report_id", "reportId", "id"]
        for key in candidateKeys {
            if let reportID = dictionary[key] as? String,
               !reportID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return reportID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let dataDictionary = dictionary["data"] as? [String: Any] {
            for key in candidateKeys {
                if let reportID = dataDictionary[key] as? String,
                   !reportID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return reportID.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    private static func extractCarfaxHTML(from data: Data) -> String? {
        if let htmlString = String(data: data, encoding: .utf8),
           htmlString.localizedCaseInsensitiveContains("<html") {
            return htmlString
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let candidateKeys = ["html", "report_html", "reportHTML", "payload", "body"]
        for key in candidateKeys {
            if let html = dictionary[key] as? String,
               html.localizedCaseInsensitiveContains("<html") {
                return html
            }
        }

        if let dataDictionary = dictionary["data"] as? [String: Any] {
            for key in candidateKeys {
                if let html = dataDictionary[key] as? String,
                   html.localizedCaseInsensitiveContains("<html") {
                    return html
                }
            }
        }

        return nil
    }
}

enum CarfaxFetchError: LocalizedError {
    case invalidURL
    case missingHTML
    case serverError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid edge function URL."
        case .missingHTML:
            return "Missing HTML payload in fetch-vhr response."
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Carfax request failed (\(statusCode)): \(message)"
            }
            return "Carfax request failed with status \(statusCode)."
        }
    }
}
