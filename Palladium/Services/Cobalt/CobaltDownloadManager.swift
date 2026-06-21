// CobaltDownloadManager.swift
// Palladium — Cobalt API Engine
// Ported from Nickel's DownloadManager.swift (Nickel-Auth removed; None/Bearer/Api-Key supported)

import Foundation
import UIKit

/// Manages Cobalt API requests: builds the request body, authenticates,
/// sends the POST, and parses the response into a `CobaltDownloadResult`.
class CobaltDownloadManager {
    static let shared = CobaltDownloadManager()

    private var shouldCancel = false

    // MARK: - Default Request Body

    static let defaultRequestBody: [String: Any] = [
        "videoQuality": "1080",
        "audioFormat": "mp3",
        "audioBitrate": "128",
        "downloadMode": "auto",
        "localProcessing": "preferred",
    ]

    // MARK: - Error Helper

    private func apiError(_ message: String, statusCode: Int = 1) -> NSError {
        NSError(domain: "CobaltAPI", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Main Fetch

    /// Sends a POST request to the configured Cobalt API and returns a typed result.
    /// - Parameters:
    ///   - inputURL: The media URL the user wants to download.
    ///   - downloadModeOverride: Overrides the `downloadMode` field in the request body ("auto" / "audio" / "mute").
    ///   - shouldCancel: Optional closure the caller can use to request cancellation mid-flight.
    func fetchCobaltURL(
        inputURL: URL,
        downloadModeOverride: String? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) async throws -> CobaltDownloadResult {
        self.shouldCancel = false

        // Keep app running in background during the API round-trip
        let bgTask = await UIApplication.shared.beginBackgroundTask(withName: "CobaltAPIRequest") {
            logOutput("[cobalt] ⚠️ Background task expired for API request")
        }
        defer {
            if bgTask != UIBackgroundTaskIdentifier.invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }

        // --- Read settings ---
        let apiURLString = UserDefaults.standard.string(forKey: CobaltSettings.Keys.apiURL) ?? ""
        let apiKey       = UserDefaults.standard.string(forKey: CobaltSettings.Keys.apiKey) ?? ""
        let authMethod   = UserDefaults.standard.string(forKey: CobaltSettings.Keys.authMethod) ?? "None"

        guard !apiURLString.isEmpty, let apiURL = URL(string: apiURLString) else {
            throw NSError(domain: "CobaltConfig", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Cobalt API URL is not configured. Please set it in Settings → Cobalt API."])
        }

        logOutput("[cobalt] Using API: \(apiURLString), auth: \(authMethod)")

        // --- Build request body ---
        var requestBody: [String: Any] = {
            if let saved = UserDefaults.standard.string(forKey: CobaltSettings.Keys.customRequestBody),
               let data = saved.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
            return Self.defaultRequestBody
        }()

        requestBody["url"] = inputURL.absoluteString
        if let override = downloadModeOverride {
            requestBody["downloadMode"] = override
        }

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        // --- Build URLRequest ---
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        // Set Authorization header (None / Bearer / Api-Key)
        switch authMethod {
        case "Bearer", "Api-Key":
            request.setValue("\(authMethod) \(apiKey)", forHTTPHeaderField: "Authorization")
            logOutput("[cobalt] Auth: \(authMethod) ***")
        default:
            logOutput("[cobalt] Auth: None")
        }

        // --- Check cancellation before sending ---
        if shouldCancel?() == true || self.shouldCancel { throw CancellationError() }

        logOutput("[cobalt] Sending request to \(apiURLString)")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        logOutput("[cobalt] Response status: \(http.statusCode)")

        // --- Handle HTTP errors ---
        guard http.statusCode == 200 else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("application/json"),
               let cobaltError = CobaltErrorTranslator.decodeResponse(from: data) {
                let msg = CobaltErrorTranslator.message(from: cobaltError)
                throw apiError(msg, statusCode: http.statusCode)
            }
            if http.statusCode == 404 {
                throw apiError("Server unavailable (404). Check your API URL.", statusCode: 404)
            }
            throw apiError("Server returned HTTP \(http.statusCode). Try again later.", statusCode: http.statusCode)
        }

        // --- Parse JSON response ---
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("application/json") else {
            throw apiError("Server returned unexpected response format. Check your API URL.")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            throw apiError("Failed to parse JSON response.")
        }

        logOutput("[cobalt] API status: \(status)")

        switch status {

        // MARK: Direct download URL
        case "redirect", "stream", "tunnel":
            guard let urlStr = json["url"] as? String, let mediaURL = URL(string: urlStr) else {
                throw apiError("No download URL in API response.")
            }
            let filename = json["filename"] as? String
            let title    = json["text"] as? String ?? json["title"] as? String
            logOutput("[cobalt] ✅ Direct URL: \(mediaURL), file: \(filename ?? "nil")")
            return .success(mediaURL, filename, title)

        // MARK: Picker (e.g. TikTok image carousels)
        case "picker":
            guard let pickerArray = json["picker"] as? [[String: Any]] else {
                throw apiError("Could not parse picker options.")
            }
            var options: [CobaltPickerOption] = pickerArray.compactMap { item in
                guard let urlStr = item["url"] as? String, let url = URL(string: urlStr) else { return nil }
                return CobaltPickerOption(label: item["type"] as? String ?? "file", url: url)
            }
            if let audioStr = json["audio"] as? String, let audioURL = URL(string: audioStr) {
                options.append(CobaltPickerOption(label: "audio", url: audioURL))
            }
            let title = json["text"] as? String ?? json["title"] as? String
            logOutput("[cobalt] ✅ Picker: \(options.count) options")
            return .pickerOptions(options, title)

        // MARK: API error
        case "error":
            if let cobaltError = CobaltErrorTranslator.decodeResponse(from: data) {
                throw apiError(CobaltErrorTranslator.message(from: cobaltError))
            }
            throw apiError(CobaltErrorTranslator.fallbackMessage)

        // MARK: Local processing required
        case "local-processing":
            if let raw = String(data: data, encoding: .utf8) {
                logOutput("[cobalt] local-processing response: \(raw.prefix(500))")
            }

            guard let type    = json["type"]    as? String,
                  let service = json["service"] as? String,
                  let tunnel  = json["tunnel"]  as? [String],
                  let outDict = json["output"]  as? [String: Any],
                  let outFilename = outDict["filename"] as? String,
                  !tunnel.isEmpty else {
                throw apiError("Failed to parse local-processing response details.")
            }

            let output = CobaltOutputDetails(
                url:      tunnel[0],
                filename: outFilename,
                size:     outDict["size"] as? Int,
                format:   outDict["type"] as? String
            )

            var audio: CobaltAudioDetails? = nil
            if let audioDict = json["audio"] as? [String: Any],
               let aURL = audioDict["url"] as? String,
               let aFilename = audioDict["filename"] as? String {
                audio = CobaltAudioDetails(url: aURL, filename: aFilename,
                                           size: audioDict["size"] as? Int,
                                           format: audioDict["format"] as? String)
            } else if type == "merge" && tunnel.count > 1 {
                let aFilename = outFilename.hasSuffix(".mp4")
                    ? outFilename.replacingOccurrences(of: ".mp4", with: "_audio.m4a")
                    : "\(outFilename)_audio.m4a"
                audio = CobaltAudioDetails(url: tunnel[1], filename: aFilename, size: nil, format: "audio/m4a")
            }

            let lpr = CobaltLocalProcessingResponse(
                status: status, type: type, service: service,
                tunnel: tunnel, output: output, audio: audio,
                isHLS: json["isHLS"] as? Bool
            )
            let title = json["text"] as? String ?? json["title"] as? String
            logOutput("[cobalt] ✅ Local-processing: type=\(type), service=\(service)")
            return .localProcessing(lpr, title)

        default:
            throw apiError("Unexpected API status: \(status)")
        }
    }

    /// Request cancellation of an in-flight download.
    func cancelDownload() {
        shouldCancel = true
        logOutput("[cobalt] 🛑 Download cancelled by user")
    }

    // MARK: - API Health Check

    /// Tests connectivity to the configured API URL.
    func testConnection() async -> Result<String, Error> {
        let urlString = UserDefaults.standard.string(forKey: CobaltSettings.Keys.apiURL) ?? ""
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            return .failure(NSError(domain: "CobaltConfig", code: 0,
                                    userInfo: [NSLocalizedDescriptionKey: "No API URL configured."]))
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cobalt = json["cobalt"] as? [String: Any],
               let version = cobalt["version"] as? String {
                return .success("Connected ✓  Cobalt v\(version)")
            }
            return .success("Connected ✓  HTTP \(http.statusCode)")
        } catch {
            return .failure(error)
        }
    }
}
