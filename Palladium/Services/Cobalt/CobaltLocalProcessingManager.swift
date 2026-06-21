// CobaltLocalProcessingManager.swift
// Palladium — Cobalt API Engine
// Ported from Nickel's LocalProcessingManager.swift + FFmpegProcessingManager.swift
// Uses SwiftFFmpeg directly (independent of Palladium's palladium_ffmpeg_bridge)

import Foundation
import SwiftFFmpeg
import AVFoundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Handles all Cobalt `local-processing` responses:
/// downloads the streams and merges / remuxes / extracts audio using FFmpeg.
class CobaltLocalProcessingManager {
    static let shared = CobaltLocalProcessingManager()

    private var shouldCancel = false

    /// Dedicated serial queue keeps FFmpeg calls off the main thread and serialised.
    private let ffmpegQueue = DispatchQueue(label: "com.palladium.cobalt.ffmpeg", qos: .userInitiated)

    enum ProcessingError: Error, LocalizedError {
        case unsupportedType(String)
        case downloadFailed(String)
        case processingFailed(String)
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let t):  return "Unsupported processing type: \(t)"
            case .downloadFailed(let r):   return "Download failed: \(r)"
            case .processingFailed(let r): return "Processing failed: \(r)"
            case .invalidURL(let u):       return "Invalid URL: \(u)"
            }
        }
    }

    // MARK: - Public Entry Point

    func processLocalResponse(
        _ response: CobaltLocalProcessingResponse,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> URL {
        shouldCancel = false
        logOutput("[cobalt/ffmpeg] Starting local processing, type: \(response.type)")
        progressHandler?("Starting \(response.type) processing…")

        guard let pType = ProcessingType(rawValue: response.type) else {
            throw ProcessingError.unsupportedType(response.type)
        }

        guard let outputURL = URL(string: response.output.url) else {
            throw ProcessingError.invalidURL(response.output.url)
        }

        let progressCB: CobaltFileDownloader.ProgressHandler = { dl, total in
            let msg = total <= 0
                ? "Downloading: \(String(format: "%.1f", dl)) MB"
                : "Downloading: \(String(format: "%.1f", dl))/\(String(format: "%.1f", total)) MB"
            progressHandler?(msg)
        }

        let mainFile = try await CobaltFileDownloader.shared.downloadFile(
            from: outputURL, type: .video,
            onProgress: progressCB,
            filename: response.output.filename,
            mediaType: response.output.format
        )

        if shouldCancel { throw CancellationError() }

        switch pType {
        case .merge:   return try await handleMerge(response: response, mainFile: mainFile, progressHandler: progressHandler)
        case .mute:    return try await handleMute(response: response, mainFile: mainFile, progressHandler: progressHandler)
        case .audio:   return try await handleAudio(response: response, mainFile: mainFile, progressHandler: progressHandler)
        case .remux:   return try await handleRemux(response: response, mainFile: mainFile, progressHandler: progressHandler)
        case .gif:     return try await handleGif(response: response, mainFile: mainFile, progressHandler: progressHandler)
        case .proxy:   return try await handleProxy(response: response, mainFile: mainFile, progressHandler: progressHandler)
        }
    }

    func cancelProcessing() {
        shouldCancel = true
        logOutput("[cobalt/ffmpeg] 🛑 Processing cancelled")
    }

    // MARK: - Processing Type Handlers

    private enum ProcessingType: String, CaseIterable {
        case merge, mute, audio, remux, gif, proxy
    }

    private func handleMerge(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        progressHandler?("Downloading audio stream…")
        guard let audio = response.audio, let audioURL = URL(string: audio.url) else {
            throw ProcessingError.processingFailed("Audio file not available for merge")
        }

        // Copy video to a safe temp location so it survives the audio download
        let videoCopy = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt_video_\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: mainFile, to: videoCopy)
        if shouldCancel { try? FileManager.default.removeItem(at: videoCopy); throw CancellationError() }

        let audioFile = try await CobaltFileDownloader.shared.downloadFile(
            from: audioURL, type: .audio,
            onProgress: nil, filename: audio.filename, mediaType: audio.format,
            skipTempCleanup: true
        )
        if shouldCancel { try? FileManager.default.removeItem(at: videoCopy); throw CancellationError() }

        progressHandler?("Merging video and audio…")
        let result = try await ffmpegMerge(videoURL: videoCopy, audioURL: audioFile,
                                           filename: response.output.filename,
                                           progressHandler: progressHandler)
        try? FileManager.default.removeItem(at: videoCopy)
        return result
    }

    private func handleMute(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        progressHandler?("Removing audio track…")
        return try await ffmpegRemoveAudio(videoURL: mainFile, filename: response.output.filename, progressHandler: progressHandler)
    }

    private func handleAudio(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        progressHandler?("Extracting audio…")
        let ext = mainFile.pathExtension.lowercased()
        let audioExts = ["mp3","m4a","aac","wav","flac","ogg"]
        if audioExts.contains(ext) {
            progressHandler?("Audio file ready")
            return mainFile
        }
        return try await ffmpegExtractAudio(videoURL: mainFile, filename: response.output.filename, progressHandler: progressHandler)
    }

    private func handleRemux(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        progressHandler?("Remuxing video…")
        return try await ffmpegRemux(videoURL: mainFile, filename: response.output.filename, progressHandler: progressHandler)
    }

    private func handleProxy(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        let ext = mainFile.pathExtension.lowercased()
        let audioExts = ["mp3","m4a","aac","wav","flac","ogg","opus","webm"]
        if audioExts.contains(ext) { return mainFile }
        progressHandler?("Processing video…")
        return try await ffmpegRemux(videoURL: mainFile, filename: response.output.filename, progressHandler: progressHandler)
    }

    private func handleGif(response: CobaltLocalProcessingResponse, mainFile: URL, progressHandler: ((String) -> Void)?) async throws -> URL {
        if mainFile.pathExtension.lowercased() == "gif" {
            if UIImage(contentsOfFile: mainFile.path) != nil { return mainFile }
            let newName = response.output.filename.replacingOccurrences(of: ".gif", with: ".mp4")
            let newURL = FileManager.default.temporaryDirectory.appendingPathComponent(newName)
            try FileManager.default.moveItem(at: mainFile, to: newURL)
            return newURL
        }
        return mainFile
    }

    // MARK: - FFmpeg Operations

    private func ffmpegMerge(videoURL: URL, audioURL: URL, filename: String, progressHandler: ((String) -> Void)?) async throws -> URL {
        let fmt = (filename as NSString).pathExtension.lowercased()
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        var args = ["-i", videoURL.path, "-i", audioURL.path,
                    "-map", "0:v", "-map", "1:a",
                    "-c:v", "copy", "-c:a", "copy"]
        if fmt == "mp4" { args += ["-movflags", "faststart+frag_keyframe+empty_moov"] }
        args += ["-f", fmt == "mkv" ? "matroska" : fmt, "-y", outURL.path]

        return try await executeFFmpeg(args: args, output: outURL, progressHandler: progressHandler)
    }

    private func ffmpegRemoveAudio(videoURL: URL, filename: String, progressHandler: ((String) -> Void)?) async throws -> URL {
        let fmt = (filename as NSString).pathExtension.lowercased()
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        var args = ["-i", videoURL.path, "-map", "0:v:0", "-c:v", "copy", "-an"]
        if fmt == "mp4" { args += ["-movflags", "faststart+frag_keyframe+empty_moov"] }
        args += ["-f", fmt == "mkv" ? "matroska" : fmt, "-y", outURL.path]

        return try await executeFFmpeg(args: args, output: outURL, progressHandler: progressHandler)
    }

    private func ffmpegExtractAudio(videoURL: URL, filename: String, progressHandler: ((String) -> Void)?) async throws -> URL {
        let ext = (filename as NSString).pathExtension.lowercased()
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let codec: String
        switch ext {
        case "mp3": codec = "libmp3lame"
        case "aac": codec = "aac"
        case "wav": codec = "pcm_s16le"
        default:    codec = "copy"
        }
        let args = ["-i", videoURL.path, "-vn", "-c:a", codec, "-y", outURL.path]
        return try await executeFFmpeg(args: args, output: outURL, progressHandler: progressHandler)
    }

    private func ffmpegRemux(videoURL: URL, filename: String, hasAudio: Bool = true, progressHandler: ((String) -> Void)?) async throws -> URL {
        let fmt = (filename as NSString).pathExtension.lowercased()
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        var args = ["-i", videoURL.path, "-map", "0:v:0"]
        if hasAudio {
            args += ["-map", "0:a:0", "-c:v", "copy", "-c:a", "copy"]
        } else {
            args += ["-c:v", "copy"]
        }
        if fmt == "mp4" { args += ["-movflags", "faststart+frag_keyframe+empty_moov"] }
        args += ["-f", fmt == "mkv" ? "matroska" : fmt, "-y", outURL.path]

        return try await executeFFmpeg(args: args, output: outURL, progressHandler: progressHandler)
    }

    // MARK: - Core FFmpeg Executor

    private func executeFFmpeg(
        args: [String],
        output outURL: URL,
        progressHandler: ((String) -> Void)?
    ) async throws -> URL {
        // Use temp file to prevent partial output being visible
        let ext = outURL.pathExtension
        let base = (outURL.lastPathComponent as NSString).deletingPathExtension
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(base)_\(UUID().uuidString).\(ext)")

        var tmpArgs = args
        if let last = tmpArgs.indices.last { tmpArgs[last] = tmpURL.path }

        logOutput("[cobalt/ffmpeg] Command: ffmpeg \(tmpArgs.joined(separator: " "))")

        return try await withCheckedThrowingContinuation { continuation in
            ffmpegQueue.async {
                if self.shouldCancel {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                SwiftFFmpeg.setLogLevel(.quiet)
                do {
                    let (exitCode, output) = try SwiftFFmpeg.execute(tmpArgs)
                    logOutput("[cobalt/ffmpeg] exit=\(exitCode) output=\(output.prefix(200))")
                    guard exitCode == 0 else {
                        continuation.resume(throwing: ProcessingError.processingFailed("FFmpeg exit \(exitCode): \(output)"))
                        return
                    }
                    // Move temp → final
                    if FileManager.default.fileExists(atPath: outURL.path) {
                        try? FileManager.default.removeItem(at: outURL)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: outURL)
                    continuation.resume(returning: outURL)
                } catch SwiftFFmpegError.executionFailed(let code, let stdout, let stderr) {
                    let detail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    logOutput("[cobalt/ffmpeg] ❌ exit=\(code): \(detail.prefix(400))")
                    try? FileManager.default.removeItem(at: tmpURL)
                    continuation.resume(throwing: ProcessingError.processingFailed("FFmpeg failed (\(code)): \(detail)"))
                } catch {
                    try? FileManager.default.removeItem(at: tmpURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
