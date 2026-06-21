// CobaltSettingsView.swift
// Palladium — Cobalt API Settings
// Allows configuring the Cobalt API endpoint, authentication, and download options.

import SwiftUI

struct CobaltSettingsView: View {
    // MARK: - State (read/write UserDefaults directly like Nickel's InstanceSettingsView)

    @State private var apiURL: String
    @State private var apiKey: String
    @State private var authMethod: String
    @State private var videoQuality: String
    @State private var audioFormat: String
    @State private var audioBitrate: String
    @State private var localProcessing: String
    @State private var disableBGDownloads: Bool

    // Tracking dirty state
    @State private var originalAPIURL: String = ""
    @State private var originalAPIKey: String = ""
    @State private var originalAuthMethod: String = ""

    @State private var connectionTestResult: String? = nil
    @State private var isTestingConnection = false
    @State private var showSaveConfirmation = false

    private let authMethods = ["None", "Bearer", "Api-Key"]
    private let videoQualities = ["best", "1080", "720", "480", "360"]
    private let audioFormats = ["mp3", "ogg", "wav", "flac", "best"]
    private let audioBitrates = ["128", "256", "320"]
    private let localProcessingOptions = [("preferred", "Preferred (allow local FFmpeg)"), ("disabled", "Disabled (server-only)")]

    init() {
        let ud = UserDefaults.standard
        let url  = ud.string(forKey: CobaltSettings.Keys.apiURL) ?? ""
        let key  = ud.string(forKey: CobaltSettings.Keys.apiKey) ?? ""
        let auth = ud.string(forKey: CobaltSettings.Keys.authMethod) ?? "None"
        _apiURL         = State(initialValue: url)
        _apiKey         = State(initialValue: key)
        _authMethod     = State(initialValue: auth)
        _originalAPIURL = State(initialValue: url)
        _originalAPIKey = State(initialValue: key)
        _originalAuthMethod = State(initialValue: auth)
        _videoQuality   = State(initialValue: ud.string(forKey: CobaltSettings.Keys.videoQuality) ?? "1080")
        _audioFormat    = State(initialValue: ud.string(forKey: CobaltSettings.Keys.audioFormat) ?? "mp3")
        _audioBitrate   = State(initialValue: ud.string(forKey: CobaltSettings.Keys.audioBitrate) ?? "128")
        _localProcessing = State(initialValue: ud.string(forKey: CobaltSettings.Keys.localProcessing) ?? "preferred")
        _disableBGDownloads = State(initialValue: ud.bool(forKey: CobaltSettings.Keys.disableBGDownloads))
    }

    // MARK: - Body

    var body: some View {
        List {
            // MARK: API Configuration
            Section(header: Label("API Configuration", systemImage: "server.rack")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API URL").font(.caption).foregroundStyle(.secondary)
                    TextField("https://cobalt.example.com", text: $apiURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Picker("Auth Method", selection: $authMethod) {
                    ForEach(authMethods, id: \.self) { Text($0).tag($0) }
                }

                if authMethod != "None" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key").font(.caption).foregroundStyle(.secondary)
                        SecureField("Enter API key", text: $apiKey)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                // Test connection
                Button(action: testConnection) {
                    HStack {
                        if isTestingConnection {
                            ProgressView().scaleEffect(0.8)
                            Text("Testing…")
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Test Connection")
                        }
                    }
                }
                .disabled(apiURL.isEmpty || isTestingConnection)

                if let result = connectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                }
            }

            // MARK: Unsaved Changes
            if hasUnsavedChanges {
                Section {
                    Button(action: saveAPISettings) {
                        Label("Save Changes", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            // MARK: Download Options
            Section(header: Label("Download Options", systemImage: "slider.horizontal.3")) {
                Picker("Video Quality", selection: $videoQuality) {
                    ForEach(videoQualities, id: \.self) { Text($0 == "best" ? "Best" : "\($0)p").tag($0) }
                }
                .onChange(of: videoQuality) { saveDownloadOptions() }

                Picker("Audio Format", selection: $audioFormat) {
                    ForEach(audioFormats, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .onChange(of: audioFormat) { saveDownloadOptions() }

                Picker("Audio Bitrate", selection: $audioBitrate) {
                    ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                .onChange(of: audioBitrate) { saveDownloadOptions() }
            }

            // MARK: Processing
            Section(header: Label("Local Processing", systemImage: "cpu")) {
                Picker("Local FFmpeg", selection: $localProcessing) {
                    ForEach(localProcessingOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: localProcessing) { saveDownloadOptions() }

                Toggle("Disable Background Downloads", isOn: $disableBGDownloads)
                    .onChange(of: disableBGDownloads) {
                        UserDefaults.standard.set(disableBGDownloads, forKey: CobaltSettings.Keys.disableBGDownloads)
                    }
            }

            // MARK: Help
            Section(header: Label("Help", systemImage: "questionmark.circle")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Getting a Cobalt API URL")
                        .font(.headline)
                    Text("You need a Cobalt API server. You can:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• Self-host: github.com/imputnet/cobalt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• Use a public instance from getnickel.app/instances")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• Use Nickel-Auth (requires Bearer token from a Nickel auth server)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Cobalt API")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Computed

    private var hasUnsavedChanges: Bool {
        apiURL != originalAPIURL || apiKey != originalAPIKey || authMethod != originalAuthMethod
    }

    // MARK: - Actions

    private func saveAPISettings() {
        let ud = UserDefaults.standard
        ud.set(apiURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: CobaltSettings.Keys.apiURL)
        ud.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: CobaltSettings.Keys.apiKey)
        ud.set(authMethod, forKey: CobaltSettings.Keys.authMethod)
        originalAPIURL    = apiURL
        originalAPIKey    = apiKey
        originalAuthMethod = authMethod
        connectionTestResult = nil
    }

    private func saveDownloadOptions() {
        let ud = UserDefaults.standard
        ud.set(videoQuality,    forKey: CobaltSettings.Keys.videoQuality)
        ud.set(audioFormat,     forKey: CobaltSettings.Keys.audioFormat)
        ud.set(audioBitrate,    forKey: CobaltSettings.Keys.audioBitrate)
        ud.set(localProcessing, forKey: CobaltSettings.Keys.localProcessing)
    }

    private func testConnection() {
        // Save current values before testing
        let testURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !testURL.isEmpty else { return }

        // Temporarily write to UserDefaults so CobaltDownloadManager can read
        UserDefaults.standard.set(testURL, forKey: CobaltSettings.Keys.apiURL)

        isTestingConnection = true
        connectionTestResult = nil

        Task {
            let result = await CobaltDownloadManager.shared.testConnection()
            await MainActor.run {
                isTestingConnection = false
                switch result {
                case .success(let msg): connectionTestResult = msg
                case .failure(let err): connectionTestResult = "❌ \(err.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CobaltSettingsView()
    }
}
