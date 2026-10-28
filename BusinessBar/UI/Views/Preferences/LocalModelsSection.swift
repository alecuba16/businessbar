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
/// start/stop with live status, model catalog with explicit downloads,
/// and custom model provisioning from a Hugging Face repo id.
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
    @State private var customRepoText = ""
    @State private var customCheck: MLXRepoInspector.Report?
    @State private var customError: String?
    @State private var customChecking = false
    @State private var customEntries: [MLXModelCatalog.Entry] = []

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
        _customEntries = State(initialValue: MLXModelCatalog.customEntries)
    }

    private var uvPath: String? { MLXEnvironment.locateUV() }

    var body: some View {
        Section {
            if let uv = uvPath {
                serverControls
                modelCatalog
                customModelProvisioning
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
        var text = "Runs a local mlx-lm server on 127.0.0.1 for on-device chat. Models download only when you press Download, never automatically. Weights live in ~/.cache/huggingface. Paste any MLX-format repo id below the catalog and press Check to provision it: the check is the only network call and runs on your command."
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
            ForEach(customEntries) { entry in
                modelRow(entry, isCustom: true)
            }
        }
    }

    private func modelRow(_ entry: MLXModelCatalog.Entry, isCustom: Bool = false) -> some View {
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
                    kindPill(entry.kind)
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
            modelRowControls(entry, isDownloaded: isDownloaded, isDownloading: isDownloading, fit: fit, isFinished: isFinished, isCustom: isCustom)
        }
    }

    @ViewBuilder
    private func modelRowControls(
        _ entry: MLXModelCatalog.Entry,
        isDownloaded: Bool,
        isDownloading: Bool,
        fit: MLXModelCatalog.Fit,
        isFinished: Bool,
        isCustom: Bool = false
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
                    if isCustom {
                        removeCustomEntry(entry)
                    }
                    refreshDownloads()
                }
                .controlSize(.small)
                .help(isCustom ? "Delete the downloaded weights and remove the entry" : "Delete the downloaded weights")
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

    private func kindPill(_ kind: MLXModelCatalog.Kind) -> some View {
        Text(kind.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    kind == .textAndImages
                        ? Color.accentColor.opacity(0.15)
                        : Color.secondary.opacity(0.15)
                )
            )
            .help(kind == .textAndImages
                ? "Accepts text and image prompts, served through mlx-vlm"
                : "Text prompts only, served through mlx-lm")
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

    // MARK: Custom model provisioning

    /// Paste a HF repo id, Check fetches its metadata (explicit network
    /// action), the preview card shows capabilities and tech details, and
    /// Add registers it as a catalog entry.
    private var customModelProvisioning: some View {
        Group {
            HStack {
                TextField("Hugging Face repo id, e.g. mlx-community/Model-4bit", text: $customRepoText)
                    .onChange(of: customRepoText) { _ in
                        // A new id invalidates the previous check result.
                        customCheck = nil
                        customError = nil
                    }
                Button(customChecking ? "Checking…" : "Check") {
                    runRepoCheck()
                }
                .controlSize(.small)
                .disabled(customChecking || customRepoText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if customChecking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching repo details from Hugging Face…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let error = customError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let report = customCheck {
                customPreviewCard(report)
            }
        }
    }

    private func customPreviewCard(_ report: MLXRepoInspector.Report) -> some View {
        let fit = MLXModelCatalog.fit(ramBytes: report.ramBytes, installedRAM: installedRAM)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(report.displayName)
                    .fontWeight(.medium)
                fitPill(fit)
                kindPill(report.kind)
            }
            Text(report.repoID)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text("\(ByteCountFormatter.string(fromByteCount: report.sizeBytes, countStyle: .file)) on disk")
                Text("~\(ByteCountFormatter.string(fromByteCount: report.ramBytes, countStyle: .memory)) RAM")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text(report.architecture)
                if let context = report.contextLength {
                    Text("\(context) token context")
                }
                if let quant = report.quantization {
                    Text(quant)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Button("Add to catalog") {
                addCustomFromReport(report)
            }
            .controlSize(.small)
            .disabled(fit == .wontFit)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func runRepoCheck() {
        customChecking = true
        customError = nil
        customCheck = nil
        let repoID = customRepoText
        Task {
            do {
                let report = try await MLXRepoInspector.check(repoID: repoID)
                await MainActor.run {
                    customCheck = report
                    customChecking = false
                }
            } catch {
                await MainActor.run {
                    customError = error.localizedDescription
                    customChecking = false
                }
            }
        }
    }

    private func addCustomFromReport(_ report: MLXRepoInspector.Report) {
        let entry = MLXModelCatalog.Entry(
            id: report.repoID,
            displayName: report.displayName,
            sizeBytes: report.sizeBytes,
            ramBytes: report.ramBytes,
            kind: report.kind
        )
        MLXModelCatalog.addCustomEntry(entry)
        customEntries = MLXModelCatalog.customEntries
        customCheck = nil
        customRepoText = ""
        refreshDownloads()
    }

    private func removeCustomEntry(_ entry: MLXModelCatalog.Entry) {
        MLXModelCatalog.removeCustomEntry(id: entry.id)
        customEntries = MLXModelCatalog.customEntries
        if activeModelID == entry.id {
            activeModelID = MLXServerConfig.activeModelID()
            updateLocalProfile()
        }
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
        let all = MLXModelCatalog.entries + customEntries
        downloadedCache = all
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