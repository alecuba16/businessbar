import BusinessBarCore
import SwiftUI

// MARK: - LocalModelsSheet

/// Sheet wrapper for the on-device MLX setup: server controls, model
/// catalog with explicit downloads, and server settings. The presenting
/// tab refreshes its providers list when the sheet dismisses.
struct LocalModelsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LocalModelsSection()
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

// MARK: - LocalModelsSection

/// Preferences section for the on-device MLX server: requirement check,
/// start/stop with live status, model catalog with explicit downloads.
struct LocalModelsSection: View {
    @ObservedObject private var server = MLXServerManager.shared
    @ObservedObject private var store = MLXModelStore.shared

    @State private var portText: String
    @State private var idleText: String
    @State private var keepLoaded: Bool
    @State private var activeModelID: String?
    @State private var statusDetail = ""
    @State private var downloadedCache: [String] = []
    @State private var localProfileCreated = false

    private let installedRAM = Int64(ProcessInfo.processInfo.physicalMemory)

    init() {
        _portText = State(initialValue: String(MLXServerConfig.port()))
        _idleText = State(initialValue: String(MLXServerConfig.idleMinutes()))
        _keepLoaded = State(initialValue: MLXServerConfig.keepLoaded())
        _activeModelID = State(initialValue: MLXServerConfig.activeModelID())
        // The sheet rebuilds this view on every open, so seed from the store
        // instead of assuming the button has not been pressed yet.
        _localProfileCreated = State(initialValue:
            CompanionConfigService.chatProviders().contains { $0.isLocalMLX == true })
    }

    private var uvPath: String? { MLXEnvironment.locateUV() }

    var body: some View {
        Section {
            if let uv = uvPath {
                serverControls
                modelCatalog
                serverSettings
            } else {
                Text("Install uv first: brew install uv. The local server runs MLX models through it.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Local models (MLX)")
        } footer: {
            Text(footerText)
        }
        .onReceive(NotificationCenter.default.publisher(for: MLXServerManager.stateDidChangeNotification)) { _ in
            refreshStatus()
        }
        .onReceive(store.$download) { _ in
            refreshDownloads()
        }
        .onAppear {
            refreshDownloads()
            refreshStatus()
        }
    }

    private var footerText: String {
        if uvPath == nil {
            return "On-device models run through a local server. Nothing downloads until you press a Download button."
        }
        var text = "Runs a local mlx-lm server on 127.0.0.1 for on-device chat. Models download only when you press Download, never automatically. Weights live in ~/.cache/huggingface."
        if keepLoaded {
            text += " Keep loaded is on: the model stays in memory until you stop the server."
        } else {
            text += " The server stops after \(idleText) min without requests; the next message starts it again."
        }
        return text
    }

    // MARK: Server controls

    private var serverControls: some View {
        Group {
            if let modelID = activeModelID {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverStateLabel)
                            .fontWeight(.medium)
                        if !statusDetail.isEmpty {
                            Text(statusDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if server.state.isRunning || server.state == .starting {
                        Button("Stop") { server.stop() }
                            .controlSize(.small)
                    } else {
                        Button("Start") {
                            Task { @MainActor in
                                statusDetail = ""
                                do {
                                    try await server.start(modelID: modelID)
                                } catch {
                                    statusDetail = error.localizedDescription
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(!MLXModelCatalog.isDownloaded(modelID: modelID))
                    }
                }

                if case .running = server.state, server.residentBytes > 0 {
                    Text("Memory: \(ByteCountFormatter.string(fromByteCount: server.residentBytes, countStyle: .memory))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Pick a model below to use the local server.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var serverStateLabel: String {
        switch server.state {
        case .stopped:
            return MLXModelCatalog.isDownloaded(modelID: activeModelID ?? "")
                ? "Stopped"
                : "No model downloaded yet"
        default:
            return server.state.label
        }
    }

    // MARK: Model catalog

    private var modelCatalog: some View {
        Group {
            ForEach(MLXModelCatalog.entries) { entry in
                modelRow(entry)
            }
        }
    }

    private func modelRow(_ entry: MLXModelCatalog.Entry) -> some View {
        let isDownloaded = downloadedCache.contains(entry.id)
        let fit = MLXModelCatalog.fit(ramBytes: entry.ramBytes, installedRAM: installedRAM)
        let isDownloading = store.download?.modelID == entry.id && store.download?.isFinished == false
        let isFinished = store.download?.modelID == entry.id && store.download?.isFinished == true

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .fontWeight(.medium)
                    fitPill(fit)
                }
                Text("\(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)) on disk")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isDownloading, let state = store.download {
                    ProgressView(value: state.fraction) {
                        Text("\(ByteCountFormatter.string(fromByteCount: state.bytesDone, countStyle: .file)) of ~\(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))")
                            .font(.caption2)
                    }
                }
                if isFinished, let state = store.download {
                    if let failure = state.failureReason {
                        Text(failure)
                            .font(.caption)
                            .foregroundColor(.red)
                    } else {
                        Text("Downloaded")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            Spacer()
            if activeModelID == entry.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .help("Active local model")
            }
            modelRowControls(entry, isDownloaded: isDownloaded, isDownloading: isDownloading, fit: fit, isFinished: isFinished)
        }
    }

    @ViewBuilder
    private func modelRowControls(
        _ entry: MLXModelCatalog.Entry,
        isDownloaded: Bool,
        isDownloading: Bool,
        fit: MLXModelCatalog.Fit,
        isFinished: Bool
    ) -> some View {
        if isDownloading {
            Button("Cancel") {
                store.cancelDownload()
            }
            .controlSize(.small)
        } else {
            if isDownloaded {
                Button("Delete") {
                    try? store.delete(modelID: entry.id)
                    refreshDownloads()
                }
                .controlSize(.small)
            } else {
                Button("Download") {
                    do {
                        try store.startDownload(modelID: entry.id)
                    } catch {
                        statusDetail = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .disabled(fit == .wontFit)
                Button(activeModelID == entry.id ? "Active" : "Use") {
                    setActiveModel(entry)
                }
                .controlSize(.small)
                .disabled(activeModelID == entry.id)
            }
        }
    }

    private func fitPill(_ fit: MLXModelCatalog.Fit) -> some View {
        Text(fit.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    fit == .fits ? Color.green.opacity(0.2)
                        : fit == .mayBeSlow ? Color.yellow.opacity(0.2)
                        : Color.red.opacity(0.2)
                )
            )
            .help("Against \(ByteCountFormatter.string(fromByteCount: installedRAM, countStyle: .memory)) of installed memory")
    }

    // MARK: Settings

    private var serverSettings: some View {
        Group {
            TextField("Port", text: $portText)
                .onChange(of: portText) { _, newValue in
                    if let port = Int(newValue), (1...65_535).contains(port) {
                        MLXServerConfig.setPort(port)
                        updateLocalProfile()
                    }
                }
            TextField("Idle stop (minutes)", text: $idleText)
                .onChange(of: idleText) { _, newValue in
                    if let minutes = Int(newValue), minutes > 0 {
                        MLXServerConfig.setIdleMinutes(minutes)
                    }
                }
            Toggle("Keep model loaded", isOn: $keepLoaded)
                .onChange(of: keepLoaded) { _, newValue in
                    MLXServerConfig.setKeepLoaded(newValue)
                }
            Button(localProfileCreated ? "Local provider added" : "Add chat provider for local model") {
                if CompanionConfigService.upsertLocalMLXProvider() != nil {
                    localProfileCreated = true
                }
            }
            .controlSize(.small)
            .disabled(activeModelID == nil)
        }
    }

    // MARK: Actions

    private func setActiveModel(_ entry: MLXModelCatalog.Entry) {
        MLXServerConfig.setActiveModelID(entry.id)
        activeModelID = entry.id
        // A running server keeps its old model; switching restarts it on
        // the next chat request or explicit Start.
        updateLocalProfile()
    }

    private func updateLocalProfile() {
        if CompanionConfigService.upsertLocalMLXProvider() != nil {
            localProfileCreated = true
        }
    }

    private func refreshDownloads() {
        downloadedCache = MLXModelCatalog.entries
            .filter { MLXModelCatalog.isDownloaded(modelID: $0.id) }
            .map(\.id)
    }

    private func refreshStatus() {
        // The published state already drives the labels; this exists so
        // the onReceive has a place to clear stale details when idle.
        if case .failed = server.state {
            if let modelID = activeModelID, MLXModelCatalog.isDownloaded(modelID: modelID) {
                return
            }
            statusDetail = ""
        }
    }
}