import Foundation
import Supabase

struct VINDecodeCacheResult: Decodable, Equatable {
    let vin: String
    let year: String
    let make: String
    let model: String
    let trim: String
    let bodyClass: String
    let driveType: String
    let engine: String
    let source: String
}

enum VINDecodeCacheFetcher {
    static func decodeAndCache(vin: String) async throws -> VINDecodeCacheResult {
        print("🚀 VIN DECODE: requesting decode-vin-cache for \(vin)")
        do {
            let result: VINDecodeCacheResult = try await supabase.functions.invoke(
                "decode-vin-cache",
                options: FunctionInvokeOptions(
                    body: ["vin": vin]
                )
            )
            print("✅ VIN DECODE: \(vin) -> \(result.year) \(result.make) \(result.model) [\(result.source)]")
            return result
        } catch let FunctionsError.httpError(code, data) {
            let serverMessage = extractErrorMessage(from: data)
            print("🔴 VIN DECODE: server error \(code) for \(vin): \(serverMessage ?? "no-body")")
            throw VINDecodeCacheError.serverError(statusCode: code, message: serverMessage)
        } catch let decodingError as DecodingError {
            print("🔴 VIN DECODE: invalid payload for \(vin): \(decodingError.localizedDescription)")
            throw VINDecodeCacheError.invalidPayload
        } catch {
            print("🔴 VIN DECODE: unexpected error for \(vin): \(error.localizedDescription)")
            throw error
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let error = dictionary["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }
}

enum VINDecodeCacheError: LocalizedError {
    case invalidPayload
    case serverError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid payload from decode-vin-cache."
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "VIN decode failed (\(statusCode)): \(message)"
            }
            return "VIN decode failed with status \(statusCode)."
        }
    }
}
