// CobaltSettings.swift
// Palladium — Cobalt API Engine
// Persistent configuration for the Cobalt API download engine.

import Foundation

/// All UserDefaults keys for Cobalt API settings.
/// Prefixed with "cobalt_" to avoid collisions with Palladium's existing keys.
enum CobaltSettings {
    enum Keys {
        static let apiURL           = "cobalt_apiURL"
        static let apiKey           = "cobalt_apiKey"
        static let authMethod       = "cobalt_authMethod"    // "None" / "Bearer" / "Api-Key"
        static let videoQuality     = "cobalt_videoQuality"  // "best" / "1080" / "720" / "480"
        static let audioFormat      = "cobalt_audioFormat"   // "mp3" / "ogg" / "wav" / "best"
        static let audioBitrate     = "cobalt_audioBitrate"  // "128" / "256" / "320"
        static let localProcessing  = "cobalt_localProcessing" // "preferred" / "disabled"
        static let disableBGDownloads = "cobalt_disableBGDownloads"
        static let customRequestBody  = "cobalt_customRequestBody" // JSON string
    }

    // MARK: - Defaults

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.apiURL:           "",
            Keys.apiKey:           "",
            Keys.authMethod:       "None",
            Keys.videoQuality:     "1080",
            Keys.audioFormat:      "mp3",
            Keys.audioBitrate:     "128",
            Keys.localProcessing:  "preferred",
            Keys.disableBGDownloads: false,
        ])
    }

    // MARK: - Computed Request Body

    /// Builds the JSON request body from stored preferences,
    /// used when no `customRequestBody` JSON override is set.
    static func defaultRequestBody(downloadModeOverride: String? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "videoQuality":   UserDefaults.standard.string(forKey: Keys.videoQuality) ?? "1080",
            "audioFormat":    UserDefaults.standard.string(forKey: Keys.audioFormat)  ?? "mp3",
            "audioBitrate":   UserDefaults.standard.string(forKey: Keys.audioBitrate) ?? "128",
            "downloadMode":   downloadModeOverride ?? "auto",
            "localProcessing": UserDefaults.standard.string(forKey: Keys.localProcessing) ?? "preferred",
        ]
        return body
    }
}
