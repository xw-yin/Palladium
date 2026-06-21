// CobaltFileDownloader.swift
// Palladium — Cobalt API Engine
// Ported from Nickel by TfourJ

import Foundation
import UIKit

/// Downloads files from Cobalt API tunnel URLs.
/// Supports background download sessions with foreground fallback.
class CobaltFileDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = CobaltFileDownloader()

    typealias ProgressHandler = (Double, Double) -> Void

    enum DownloadType {
        case video, image, audio
    }

    private var progressHandler: ProgressHandler?

    private lazy var bgSession: URLSession = {
        let id = "\(Bundle.main.bundleIdentifier ?? "app.getpalladium.palladium").cobalt.filedownloader"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var downloadContinuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadType: DownloadType?
    private var targetURL: URL?
    private var providedMediaType: String?

    /// Downloads a file from `url` to a temporary location, returning the local file URL.
    func downloadFile(
        from url: URL,
        type: DownloadType,
        onProgress: ProgressHandler? = nil,
        filename: String? = nil,
        mediaType: String? = nil,
        skipTempCleanup: Bool = false
    ) async throws -> URL {
        if !skipTempCleanup { clearTempFiles() }

        downloadType = type
        progressHandler = onProgress
        providedMediaType = mediaType

        let tempDir = FileManager.default.temporaryDirectory

        // Resolve target filename / extension
        var contentType: String? = mediaType
        if mediaType == nil {
            if let httpResponse = try? await fetchContentTypeHeader(from: url) {
                contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            }
        }

        if let filename, !filename.isEmpty {
            targetURL = tempDir.appendingPathComponent(filename)
        } else {
            let ext: String
            if let ct = contentType, let e = mimeTypeToExtension(ct) {
                ext = e
            } else {
                let raw = url.pathExtension
                if raw.isEmpty {
                    ext = type == .audio ? "mp3" : type == .image ? "jpg" : "mp4"
                } else {
                    ext = raw
                }
            }
            targetURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        }

        let useBackground = !(UserDefaults.standard.object(forKey: "cobalt_disableBGDownloads") as? Bool ?? false)
        let session = useBackground ? bgSession : URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()

        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
        }.0
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadContinuation?.resume(throwing: NSError(domain: "CobaltFileDownloader", code: -999,
            userInfo: [NSLocalizedDescriptionKey: "Download cancelled"]))
        downloadContinuation = nil
        targetURL = nil
        downloadType = nil
        progressHandler = nil
        providedMediaType = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target = targetURL, let type = downloadType else {
            downloadContinuation?.resume(throwing: NSError(domain: "CobaltFileDownloader", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Missing target URL or download type"]))
            return
        }

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)

            let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
            let size = attrs[.size] as? Int64 ?? 0
            if size == 0 {
                downloadContinuation?.resume(throwing: NSError(domain: "CobaltFileDownloader", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file is 0 bytes."]))
                return
            }

            if let response = downloadTask.response {
                downloadContinuation?.resume(returning: (target, response))
            } else {
                downloadContinuation?.resume(throwing: URLError(.badServerResponse))
            }
            _ = type // silence unused warning
        } catch {
            downloadContinuation?.resume(throwing: error)
        }

        downloadContinuation = nil
        self.targetURL = nil
        self.downloadType = nil
        self.providedMediaType = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let downloadedMB = Double(totalBytesWritten) / 1_000_000.0
        let totalMB = Double(totalBytesExpectedToWrite) / 1_000_000.0
        progressHandler?(downloadedMB, totalMB)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let code = (error as NSError).code
        let isCancelled = code == NSURLErrorCancelled

        // Fallback to foreground session if background fails (common with sideloading)
        let disableBG = UserDefaults.standard.object(forKey: "cobalt_disableBGDownloads") as? Bool ?? false
        if !disableBG && !isCancelled, let request = task.originalRequest {
            showBackgroundFallbackAlert()
            let fgSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let newTask = fgSession.downloadTask(with: request)
            downloadTask = newTask
            newTask.resume()
            return
        }

        downloadContinuation?.resume(throwing: error)
        downloadContinuation = nil
        targetURL = nil
        downloadType = nil
        progressHandler = nil
        providedMediaType = nil
    }

    // MARK: - Private Helpers

    private func fetchContentTypeHeader(from url: URL) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }

    private func clearTempFiles() {
        let dir = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private func showBackgroundFallbackAlert() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
            let alert = UIAlertController(
                title: "Download Method Changed",
                message: "Background download isn't available with current signing. Switched to foreground download.\n\nYou can disable this notice in Cobalt API settings.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            root.present(alert, animated: true)
        }
    }

    private func mimeTypeToExtension(_ mimeType: String) -> String? {
        let m = mimeType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? mimeType.lowercased()
        switch true {
        case m.contains("audio/mpeg") || m == "audio/mp3": return "mp3"
        case m.contains("audio/mp4") || m.contains("audio/x-m4a"): return "m4a"
        case m.contains("audio/aac"): return "aac"
        case m.contains("audio/wav") || m.contains("audio/x-wav"): return "wav"
        case m.contains("audio/ogg"): return "ogg"
        case m.contains("audio/flac"): return "flac"
        case m.contains("audio/webm") || m.contains("audio/webp"): return "webm"
        case m.contains("video/mp4"): return "mp4"
        case m.contains("video/quicktime"): return "mov"
        case m.contains("video/webm"): return "webm"
        case m.contains("video/x-matroska"): return "mkv"
        case m.contains("image/jpeg") || m.contains("image/jpg"): return "jpg"
        case m.contains("image/png"): return "png"
        case m.contains("image/gif"): return "gif"
        case m.contains("image/webp"): return "webp"
        default: return nil
        }
    }
}
