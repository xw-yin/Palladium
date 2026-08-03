// ContentView+CobaltFlow.swift
// Palladium — Cobalt API Engine integration
// Handles the complete download flow when DownloadEngine == .cobalt

import SwiftUI
import UIKit

extension ContentView {

    // MARK: - Cobalt Download Entry Point

    /// Called by runDownloadFlow() when the user has selected the Cobalt engine.
    func runCobaltDownloadFlow(urlString: String, afterDownloadOverride: AfterDownloadBehavior? = nil) {
        guard !isRunning, !isPackageRunning else { return }
        guard !urlString.isEmpty, let inputURL = URL(string: urlString) else {
            downloadErrorText = "Invalid URL"
            return
        }

        // Verify API URL is configured
        let apiURL = UserDefaults.standard.string(forKey: CobaltSettings.Keys.apiURL) ?? ""
        guard !apiURL.isEmpty else {
            downloadErrorText = "Cobalt API URL not configured. Please set it in Settings → Cobalt API."
            return
        }

        consoleLogStore.clearAll()
        downloadErrorText = nil
        completedDownloadResult = nil
        playlistProgress = nil
        isRunning = true
        syncIdleTimerDisabled()
        statusText = "running"
        progressText = "Connecting to Cobalt API…"
        downloadCancelRequested = false

        appendConsoleText("[cobalt] starting download for: \(urlString)\n")

        // Map current Palladium preset → Cobalt downloadMode
        let modeOverride: String? = {
            switch selectedPreset {
            case .audio: return "audio"
            case .mute:  return "mute"
            default:     return nil  // let API decide ("auto")
            }
        }()

        let effectiveBehavior = afterDownloadOverride ?? afterDownloadBehavior

        currentDownloadTask = Task { @MainActor in
            await performCobaltDownload(
                inputURL: inputURL,
                modeOverride: modeOverride,
                behavior: effectiveBehavior
            )
        }
    }

    // MARK: - Core Cobalt Download Loop

    @MainActor
    private func performCobaltDownload(
        inputURL: URL,
        modeOverride: String?,
        behavior: AfterDownloadBehavior
    ) async {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "PalladiumCobalt") {
            logOutput("[cobalt] ⚠️ Background task expired")
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        do {
            // ① Call Cobalt API
            let result = try await CobaltDownloadManager.shared.fetchCobaltURL(
                inputURL: inputURL,
                downloadModeOverride: modeOverride,
                shouldCancel: { self.downloadCancelRequested }
            )

            if downloadCancelRequested { throw CancellationError() }

            // ② Handle each result type
            switch result {

            case .success(let mediaURL, let filename, let title):
                appendConsoleText("[cobalt] ✅ Received download URL\n")
                progressText = "Downloading file…"
                let localURL = try await downloadCobaltFile(from: mediaURL, filename: filename)
                if downloadCancelRequested { throw CancellationError() }
                await finishCobaltDownload(fileURL: localURL, title: title, sourceURL: inputURL, behavior: behavior)

            case .pickerOptions(let options, let title):
                appendConsoleText("[cobalt] 📋 Picker: \(options.count) options\n")
                await handleCobaltPicker(options: options, title: title, behavior: behavior)

            case .localProcessing(let response, let title):
                appendConsoleText("[cobalt] 🔧 Local processing: type=\(response.type)\n")
                progressText = "Processing media locally…"
                let processedURL = try await CobaltLocalProcessingManager.shared.processLocalResponse(
                    response,
                    progressHandler: { msg in
                        Task { @MainActor in self.progressText = msg }
                    }
                )
                if downloadCancelRequested { throw CancellationError() }
                await finishCobaltDownload(fileURL: processedURL, title: title, sourceURL: inputURL, behavior: behavior)
            }

        } catch is CancellationError {
            appendConsoleText("[cobalt] 🛑 Download cancelled\n")
            progressText = String(localized: "download.prompt.idle")
            statusText = "idle"
            isRunning = false
            syncIdleTimerDisabled()

        } catch {
            appendConsoleText("[cobalt] ❌ Error: \(error.localizedDescription)\n")
            downloadErrorText = error.localizedDescription
            progressText = String(localized: "download.status.failed")
            statusText = "idle"
            isRunning = false
            syncIdleTimerDisabled()
        }
    }

    // MARK: - File Download Helper

    private func downloadCobaltFile(from url: URL, filename: String?) async throws -> URL {
        return try await CobaltFileDownloader.shared.downloadFile(
            from: url,
            type: .video,
            onProgress: { dl, total in
                Task { @MainActor in
                    if total > 0 {
                        self.progressText = "Downloading: \(String(format: "%.1f", dl))/\(String(format: "%.1f", total)) MB"
                    } else {
                        self.progressText = "Downloading: \(String(format: "%.1f", dl)) MB"
                    }
                }
            },
            filename: filename
        )
    }

    // MARK: - Picker UI

    @MainActor
    private func handleCobaltPicker(
        options: [CobaltPickerOption],
        title: String?,
        behavior: AfterDownloadBehavior
    ) async {
        // Present action sheet for user to choose from picker options
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            downloadErrorText = "Could not display picker options"
            progressText = String(localized: "download.status.failed")
            statusText = "idle"
            isRunning = false
            syncIdleTimerDisabled()
            return
        }

        let alert = UIAlertController(
            title: title ?? "Select Media",
            message: "Choose which file to download:",
            preferredStyle: .actionSheet
        )

        for (index, option) in options.enumerated() {
            let label = option.label == "photo" ? "Photo \(index + 1)"
                      : option.label == "audio" ? "Audio Track"
                      : option.label.capitalized
            alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                Task {
                    await self.performCobaltDownload(
                        inputURL: option.url,
                        modeOverride: option.label == "audio" ? "audio" : nil,
                        behavior: behavior
                    )
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            Task { @MainActor in
                self.progressText = String(localized: "download.prompt.idle")
                self.statusText = "idle"
                self.isRunning = false
                self.syncIdleTimerDisabled()
            }
        })

        root.present(alert, animated: true)
    }

    // MARK: - Post Download

    @MainActor
    private func finishCobaltDownload(fileURL: URL, title: String?, sourceURL: URL?, behavior: AfterDownloadBehavior) async {
        appendConsoleText("[cobalt] ✅ File ready: \(fileURL.lastPathComponent)\n")
        progressText = "Download complete"
        statusText = "idle"
        isRunning = false
        syncIdleTimerDisabled()

        // Reuse Palladium's existing AfterDownloadBehavior logic
        let result = CompletedDownloadResult(
            items: [fileURL],
            primaryMediaURL: fileURL,
            folderURL: fileURL.deletingLastPathComponent(),
            titleHint: title,
            sourceURL: sourceURL
        )
        completedDownloadResult = result

        switch behavior {
        case .ask:
            showDownloadActionSheet = true
        case .saveToPhotos:
            handlePostDownloadAction(.saveToPhotos, for: result)
        case .openShareSheet:
            handlePostDownloadAction(.openShareSheet, for: result)
        case .saveToApplicationFolder:
            handlePostDownloadAction(.saveToApplicationFolder, for: result)
        }
    }

    // MARK: - Cancel

    func cancelCobaltDownload() {
        downloadCancelRequested = true
        CobaltDownloadManager.shared.cancelDownload()
        CobaltFileDownloader.shared.cancelDownload()
        CobaltLocalProcessingManager.shared.cancelProcessing()
        appendConsoleText("[cobalt] 🛑 Cancel requested\n")
    }
}
