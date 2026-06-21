// CobaltModels.swift
// Palladium — Cobalt API Engine
// Data structures for Cobalt API local-processing responses

import Foundation

/// Picker option returned by Cobalt API (e.g. TikTok image carousels)
struct CobaltPickerOption: Identifiable {
    let id = UUID()
    let label: String
    let url: URL
}

/// Cobalt local-processing response top-level
struct CobaltLocalProcessingResponse {
    let status: String
    let type: String
    let service: String
    let tunnel: [String]
    let output: CobaltOutputDetails
    let audio: CobaltAudioDetails?
    let isHLS: Bool?
}

struct CobaltOutputDetails {
    let url: String
    let filename: String
    let size: Int?
    let format: String?
}

struct CobaltAudioDetails {
    let url: String
    let filename: String
    let size: Int?
    let format: String?
}

/// Result of a Cobalt API download request
enum CobaltDownloadResult {
    /// Direct download URL (redirect / stream / tunnel)
    case success(URL, String?, String?) // url, filename, title
    /// Multi-file picker (e.g. TikTok image carousel)
    case pickerOptions([CobaltPickerOption], String?) // options, title
    /// Requires local FFmpeg processing
    case localProcessing(CobaltLocalProcessingResponse, String?) // response, title
}
