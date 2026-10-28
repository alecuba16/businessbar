import BusinessBarCore
import KeyboardShortcuts
import SwiftUI

/// Tracks the Accessibility permission state for the Companion UI, the
/// same trust signal the Badges tab uses. Re-checks when the app becomes
/// active so a grant in System Settings shows up on return.
@MainActor
private final class AccessibilityPermissionModel: ObservableObject {
    @Published private(set) var isGranted = AXIsProcessTrusted()

    func refresh() {
        isGranted = AXIsProcessTrusted()
    }
}

// MARK: - CompanionTab

/// Preferences tab for the LLM Companion: enable/disable, shortcuts,
/// backend configuration and prompt templates.
struct CompanionTab: View {
    @AppStorage(Constants.Defaults.featureCompanion) private var companionEnabled = true
    @StateObject private var accessibilityPermission = AccessibilityPermissionModel()

    @State private var backend: CompanionConfigService.Backend
    @State private var searchProviderKind: String
    @State private var commandToolsEnabled: Bool
    @State private var braveKeyText: String
    @State private var tavilyKeyText: String
    @State private var customSearchEndpointText: String
    @State private var customSearchHeaderNameText: String
    @State private var customSearchKeyText: String
    @State private var acpCommandText: String
    @State private var acpArgumentsText: String
    @State private var historyMaxAgeDays: Int
    @State private var historyMaxSessions: Int
    @State private var templates: [PromptTemplate]
    @State private var editingTemplate: PromptTemplate?
    @State private var showsTemplateEditor = false
    @State private var keychainError: String?
    @State private var providers: [ChatProvider]
    @State private var editingProvider: ChatProvider?
    @State private var editingModel: (provider: ChatProvider, model: ChatModel)?
    @State private var showsProviderEditor = false
    @State private var showsModelEditor = false
    @State private var showsLocalModels = false

    private let templateStore = TemplateStore()

    init() {
        let defaults = UserDefaults.standard
        _backend = State(initialValue: CompanionConfigService.backend())
        _searchProviderKind = State(initialValue: CompanionConfigService.searchProviderKind())
        _commandToolsEnabled = State(initialValue: CompanionConfigService.commandToolsEnabled())
        _braveKeyText = State(initialValue: CompanionConfigService.braveKey())
        _tavilyKeyText = State(initialValue: CompanionConfigService.tavilyKey())
        _customSearchEndpointText = State(initialValue: defaults.string(forKey: Constants.Defaults.companionCustomSearchEndpoint) ?? "")
        _customSearchHeaderNameText = State(initialValue: CompanionConfigService.customSearchHeaderName())
        _customSearchKeyText = State(initialValue: CompanionConfigService.customSearchKey())
        _acpCommandText = State(initialValue: CompanionConfigService.acpCommand())
        _acpArgumentsText = State(initialValue: CompanionConfigService.acpArguments().joined(separator: " "))
        _historyMaxAgeDays = State(initialValue: CompanionConfigService.historyMaxAgeDays())
        _historyMaxSessions = State(initialValue: CompanionConfigService.historyMaxSessions())
        _templates = State(initialValue: TemplateStore().load())
        _providers = State(initialValue: CompanionConfigService.chatProviders())
    }

    var body: some View {
        Form {
            // MARK: Feature
            Section {
                Toggle("Enable Companion", isOn: $companionEnabled)
            } footer: {
                Text("Adds an AI chat panel and rewrite shortcuts for selected text. Off removes all shortcuts and panels.")
            }

            if companionEnabled {
                // MARK: Shortcuts
                Section {
                    KeyboardShortcuts.Recorder("Toggle chat panel:", name: .toggleCompanionChat)
                } header: {
                    Text("Keyboard Shortcuts")
                } footer: {
                    Text("The chat panel shortcut is predefined. Rewrite templates get their own shortcut below.")
                }

                // MARK: Backend
                Section {
                    Picker("Backend", selection: $backend) {
                        Text("OpenAI-compatible API").tag(CompanionConfigService.Backend.openai)
                        Text("ACP agent (stdio)").tag(CompanionConfigService.Backend.acp)
                    }
                    .onChange(of: backend) { _, newValue in
                        CompanionConfigService.setBackend(newValue)
                    }

                    if backend == .acp {
                        acpFields
                    }
                } header: {
                    Text("Model Backend")
                } footer: {
                    Text(backend == .openai
                        ? "OpenAI-compatible endpoints are configured as providers below."
                        : "Runs a local ACP agent over stdio, for example 'gemini --acp' or 'claude --acp'. The process starts with the chat panel and stops when it closes.")
                }

                if backend == .openai, !providers.isEmpty {
                    // MARK: Default chat model
                    Section {
                        Picker("Default chat model", selection: Binding(
                            get: { CompanionConfigService.selectedModel()?.model.id },
                            set: { newValue in
                                if let newValue {
                                    CompanionConfigService.setSelectedModelProfileID(newValue)
                                    providers = CompanionConfigService.chatProviders()
                                }
                            }
                        )) {
                            ForEach(providers) { provider in
                                Section(provider.name) {
                                    ForEach(provider.models) { model in
                                        Text(model.name).tag(Optional(model.id))
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Chat")
                    } footer: {
                        Text("Used by the chat panel and rewrite shortcuts when no per-message model is picked.")
                    }
                }

                // MARK: Providers
                if backend == .openai {
                    Section {
                        ForEach(providers) { provider in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.name)
                                            .fontWeight(.medium)
                                        Text(provider.baseURL)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if provider.isLocalMLX == true {
                                        Text("Local")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    Button("Edit") {
                                        editingProvider = provider
                                        showsProviderEditor = true
                                    }
                                    .controlSize(.small)
                                    Button {
                                        CompanionConfigService.deleteProvider(id: provider.id)
                                        providers = CompanionConfigService.chatProviders()
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete this provider and its models")
                                }

                                ForEach(provider.models) { model in
                                    HStack {
                                        Text(model.name)
                                            .lineLimit(1)
                                        Spacer()
                                        if CompanionConfigService.selectedModel()?.model.id == model.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                                .help("Selected for chat")
                                        }
                                        Button("Edit") {
                                            editingModel = (provider, model)
                                            showsModelEditor = true
                                        }
                                        .controlSize(.small)
                                        Button {
                                            CompanionConfigService.deleteModel(id: model.id, in: provider.id)
                                            providers = CompanionConfigService.chatProviders()
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove this model")
                                    }
                                    .padding(.leading, 12)
                                }

                                Button("Add Model") {
                                    editingModel = (provider, ChatModel(name: "", model: ""))
                                    showsModelEditor = true
                                }
                                .controlSize(.small)
                                .padding(.leading, 12)
                            }
                            .padding(.vertical, 2)
                        }

                        HStack {
                            Button("Add Provider") {
                                editingProvider = nil
                                showsProviderEditor = true
                            }
                            Button("Add Local Models") {
                                showsLocalModels = true
                            }
                        }
                    } header: {
                        Text("Providers")
                    } footer: {
                        Text("Each provider is an endpoint with its own key and one or more models. The model with the checkmark is the chat default; rewrite templates follow it. Add Local Models opens the on-device setup with its own downloads.")
                    }
                }

                // MARK: Search
                if backend == .openai {
                    Section {
                        Picker("Web search", selection: $searchProviderKind) {
                            Text("Disabled").tag("none")
                            Text("DuckDuckGo (scraped)").tag("scrape-ddg")
                            Text("Bing (scraped)").tag("scrape-bing")
                            Text("Google News (scraped)").tag("scrape-google-news")
                            Text("Brave (API key)").tag("brave")
                            Text("Tavily (API key)").tag("tavily")
                            Text("Custom (API key)").tag("custom")
                        }
                        .onChange(of: searchProviderKind) { _, newValue in
                            CompanionConfigService.setSearchProviderKind(newValue)
                        }

                        searchProviderFields
                    } header: {
                        Text("Web Search")
                    } footer: {
                        Text("Gives the model a web_search tool. Scraped engines need no key and fall back to each other when one blocks the request; API-key providers store their key in the Keychain. Applies to the OpenAI-compatible backend; ACP agents bring their own tools.")
                    }
                }

                // MARK: Command tools
                Section {
                    Toggle("Command tools", isOn: $commandToolsEnabled)
                        .onChange(of: commandToolsEnabled) { _, enabled in
                            CompanionConfigService.setCommandToolsEnabled(enabled)
                            if enabled {
                                // AppDelegate owns the notification delegate
                                // and already asked for authorization at launch.
                                CommandToolController.registerNotificationCategory()
                            }
                        }
                } header: {
                    Text("Command execution")
                } footer: {
                    Text("Gives the model run_command, read_file, and list_files tools scoped to a folder you pick in the chat panel. Read-only commands run without asking; everything else shows a confirmation card first. Applies to the OpenAI-compatible backend only.")
                }

                // MARK: Templates
                Section {
                    ForEach($templates) { $template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .fontWeight(.medium)
                                if template.action != .overlay {
                                    Text(template.action.label)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(template.prompt)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .rewriteTemplate(template.id))
                                .fixedSize()
                            Button("Edit") {
                                editingTemplate = template
                                showsTemplateEditor = true
                            }
                            .controlSize(.small)
                            Button {
                                templates.removeAll { $0.id == template.id }
                                templateStore.save(templates)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete this template")
                        }
                    }

                    Button("Add Template") {
                        editingTemplate = PromptTemplate(name: "", prompt: "[placeholder]")
                        showsTemplateEditor = true
                    }
                } header: {
                    Text("Rewrite Templates")
                } footer: {
                    Text("Use [placeholder] where the selected text goes. Assign a shortcut to a template to run that rewrite on the selection from any app. Wrap the reply in <output></output> tags in your prompt and only that text is used, with no model commentary. Replace selection swaps the selection in place when the reply carries the tags; insert after keeps the selection and adds the reply right after it. Both fall back to the overlay when direct writing is not possible.")
                }

                // MARK: History
                Section {
                    Picker("Delete conversations older than", selection: $historyMaxAgeDays) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .onChange(of: historyMaxAgeDays) { _, newValue in
                        CompanionConfigService.setHistoryMaxAgeDays(newValue)
                    }

                    Picker("Keep at most", selection: $historyMaxSessions) {
                        Text("Everything").tag(0)
                        Text("20 conversations").tag(20)
                        Text("50 conversations").tag(50)
                        Text("100 conversations").tag(100)
                    }
                    .onChange(of: historyMaxSessions) { _, newValue in
                        CompanionConfigService.setHistoryMaxSessions(newValue)
                    }
                } header: {
                    Text("Conversation History")
                } footer: {
                    Text("Cleanup runs when the app starts and after each saved reply. The history drawer in the chat panel can also delete sessions by age or all at once.")
                }

                // MARK: Accessibility Permission
                Section("Accessibility Permission") {
                    if accessibilityPermission.isGranted {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Accessibility permission granted")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Accessibility permission required")
                                    .font(.headline)
                            }

                            Text("BusinessBar needs Accessibility access to read the selected text for rewrites triggered by the template shortcuts.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button("Open System Settings") {
                                    openAccessibilitySettings()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Request Permission") {
                                    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                                    _ = AXIsProcessTrustedWithOptions(options)
                                    accessibilityPermission.refresh()
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        // Re-check whenever the app comes back to front, so a grant made
        // in System Settings is reflected immediately on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityPermission.refresh()
        }
        .sheet(isPresented: $showsTemplateEditor) {
            TemplateEditorSheet(template: editingTemplate) { saved in
                if let index = templates.firstIndex(where: { $0.id == saved.id }) {
                    templates[index] = saved
                } else {
                    templates.append(saved)
                }
                templateStore.save(templates)
                showsTemplateEditor = false
            }
        }
        .sheet(isPresented: $showsProviderEditor) {
            ProviderEditorSheet(provider: editingProvider) { saved, apiKey, headers in
                if let index = providers.firstIndex(where: { $0.id == saved.id }) {
                    providers[index] = saved
                } else {
                    providers.append(saved)
                }
                CompanionConfigService.chatProviderStore.save(providers)
                if !apiKey.isEmpty {
                    do {
                        try CompanionConfigService.setProviderAPIKey(saved.id, apiKey)
                        keychainError = nil
                    } catch {
                        keychainError = "Could not save the API key: \(error.localizedDescription)"
                    }
                }
                do {
                    try CompanionConfigService.setProviderHeaders(id: saved.id, headers)
                } catch {
                    keychainError = "Could not save the headers: \(error.localizedDescription)"
                }
                showsProviderEditor = false
            }
        }
        .sheet(isPresented: $showsModelEditor) {
            if let editingModel {
                ModelEditorSheet(model: editingModel.model) { saved in
                    if let providerIndex = providers.firstIndex(where: { $0.id == editingModel.provider.id }) {
                        if let modelIndex = providers[providerIndex].models.firstIndex(where: { $0.id == saved.id }) {
                            providers[providerIndex].models[modelIndex] = saved
                        } else {
                            providers[providerIndex].models.append(saved)
                        }
                        CompanionConfigService.chatProviderStore.save(providers)
                    }
                    showsModelEditor = false
                }
            }
        }
        .sheet(isPresented: $showsLocalModels, onDismiss: {
            providers = CompanionConfigService.chatProviders()
        }) {
            LocalModelsSheet()
        }
    }

    private var acpFields: some View {
        Group {
            TextField("Agent command, for example gemini", text: $acpCommandText)
                .onChange(of: acpCommandText) { _, newValue in
                    CompanionConfigService.setACPCommand(newValue.trimmingCharacters(in: .whitespaces))
                }

            TextField("Arguments, space separated", text: $acpArgumentsText)
                .onChange(of: acpArgumentsText) { _, newValue in
                    let arguments = newValue.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    CompanionConfigService.setACPArguments(arguments)
                }

            if acpCommandText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Enter the agent command to use the companion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchProviderFields: some View {
        switch searchProviderKind {
        case "brave":
            SecureField("Brave API key (X-Subscription-Token)", text: $braveKeyText)
                .onChange(of: braveKeyText) { _, newValue in
                    try? CompanionConfigService.setBraveKey(newValue)
                }
        case "tavily":
            SecureField("Tavily API key", text: $tavilyKeyText)
                .onChange(of: tavilyKeyText) { _, newValue in
                    try? CompanionConfigService.setTavilyKey(newValue)
                }
        case "custom":
            TextField("Endpoint URL", text: $customSearchEndpointText)
                .onChange(of: customSearchEndpointText) { _, newValue in
                    CompanionConfigService.setCustomSearchEndpoint(URL(string: newValue.trimmingCharacters(in: .whitespaces)))
                }
            TextField("API key header name (optional)", text: $customSearchHeaderNameText)
                .onChange(of: customSearchHeaderNameText) { _, newValue in
                    CompanionConfigService.setCustomSearchHeaderName(newValue)
                }
            SecureField("API key (stored in Keychain)", text: $customSearchKeyText)
                .onChange(of: customSearchKeyText) { _, newValue in
                    try? CompanionConfigService.setCustomSearchKey(newValue)
                }
        default:
            EmptyView()
        }
    }

    /// Opens System Settings to the Accessibility privacy pane, the same
    /// destination the Badges tab uses.
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - ProviderEditorSheet

/// Sheet for creating and editing a provider: name, endpoint, per-provider
/// API key and request headers. Models are managed in the list below the
/// provider row.
struct ProviderEditorSheet: View {
    @State private var provider: ChatProvider
    @State private var apiKey: String
    @State private var headers: [EditableHeaderPair]
    let onSave: (ChatProvider, String, [(name: String, value: String)]) -> Void

    @Environment(\.dismiss) private var dismiss

    init(provider: ChatProvider?, onSave: @escaping (ChatProvider, String, [(name: String, value: String)]) -> Void) {
        let initial = provider ?? ChatProvider(name: "", baseURL: "", models: [])
        _provider = State(initialValue: initial)
        _apiKey = State(initialValue: CompanionConfigService.providerAPIKey(id: initial.id))
        _headers = State(initialValue: CompanionConfigService.providerHeaders(id: initial.id).map {
            EditableHeaderPair(name: $0.name, value: $0.value)
        })
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider.name.isEmpty ? "New Provider" : "Edit Provider")
                .font(.headline)

            TextField("Name", text: $provider.name)
            TextField("Base URL (ends in /v1)", text: $provider.baseURL)
            if provider.isLocalMLX != true {
                SecureField("API Key (stored in Keychain)", text: $apiKey)
            }

            ForEach($headers) { $pair in
                HStack {
                    TextField("Header name", text: $pair.name)
                    SecureField("Value", text: $pair.value)
                    Button {
                        headers.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove header")
                }
            }
            Button("Add Header") {
                headers.append(EditableHeaderPair(name: "", value: ""))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = headers
                        .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
                    onSave(provider, apiKey, trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provider.name.isEmpty || provider.baseURL.isEmpty)
            }
        }
        .frame(width: 420, height: 360)
        .padding()
    }
}

/// Identifiable header pair for the provider editor rows.
private struct EditableHeaderPair: Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

// MARK: - ModelEditorSheet

/// Sheet for one model inside a provider: display name, model string,
/// system prompt, and the Reasoning checkbox gating the effort picker.
struct ModelEditorSheet: View {
    @State private var model: ChatModel
    let onSave: (ChatModel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Picker selection: "__custom__" reveals the custom effort text field;
    /// non-preset stored values keep it selected on open.
    @State private var effortSelection: String
    @State private var customEffort: String

    init(model: ChatModel, onSave: @escaping (ChatModel) -> Void) {
        _model = State(initialValue: model)
        let stored = model.reasoningEffort ?? ""
        _effortSelection = State(initialValue:
            CompanionConfigService.effortLevels.contains(stored) || stored.isEmpty
                ? stored : "__custom__")
        _customEffort = State(initialValue: stored)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name.isEmpty ? "New Model" : "Edit Model")
                .font(.headline)

            TextField("Name", text: $model.name)
            TextField("Model string, for example gpt-4o-mini", text: $model.model)
            TextField("System prompt (optional)", text: Binding(
                get: { model.systemPrompt ?? "" },
                set: { model.systemPrompt = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
                .lineLimit(2...4)

            Toggle("Reasoning", isOn: Binding(
                get: { model.reasoningEnabled ?? false },
                set: { model.reasoningEnabled = $0 }
            ))

            if model.reasoningEnabled == true {
                Picker("Effort", selection: $effortSelection) {
                    ForEach(CompanionConfigService.effortLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                    Text("Custom").tag("__custom__")
                }
                if effortSelection == "__custom__" {
                    TextField("Custom effort value", text: $customEffort)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if model.reasoningEnabled == true {
                        model.reasoningEffort = effortSelection == "__custom__"
                            ? customEffort
                            : effortSelection
                    } else {
                        model.reasoningEffort = nil
                    }
                    onSave(model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.name.isEmpty || model.model.isEmpty)
            }
        }
        .frame(width: 420, height: 360)
        .padding()
    }
}

// MARK: - TemplateEditorSheet

struct TemplateEditorSheet: View {
    @State var template: PromptTemplate
    let onSave: (PromptTemplate) -> Void

    /// Picker selection for the effort row: "default" maps to nil, "custom"
    /// reveals the text field; preset levels write straight into the template.
    @State private var effortSelection: String
    @State private var customEffort: String

    @Environment(\.dismiss) private var dismiss

    private static let presetLevels = CompanionConfigService.effortLevels

    init(template: PromptTemplate?, onSave: @escaping (PromptTemplate) -> Void) {
        let initial = template ?? PromptTemplate(name: "", prompt: "[placeholder]")
        _template = State(initialValue: initial)
        let stored = initial.reasoningEffort ?? ""
        if stored.isEmpty {
            _effortSelection = State(initialValue: "default")
            _customEffort = State(initialValue: "")
        } else if Self.presetLevels.contains(stored) {
            _effortSelection = State(initialValue: stored)
            _customEffort = State(initialValue: stored)
        } else {
            _effortSelection = State(initialValue: "custom")
            _customEffort = State(initialValue: stored)
        }
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.name.isEmpty ? "New Template" : "Edit Template")
                .font(.headline)

            TextField("Name", text: $template.name)

            TextField("Prompt, use [placeholder] for the selection", text: $template.prompt, axis: .vertical)
                .lineLimit(4...10)

            Picker("Action", selection: Binding(
                get: { template.action },
                set: { template.action = $0 }
            )) {
                Text("Show overlay").tag(TemplateAction.overlay)
                Text("Replace selection").tag(TemplateAction.replace)
                Text("Insert after selection").tag(TemplateAction.append)
            }
            .onChange(of: template.action) { _, _ in
                template.autoReplace = template.action == .replace
            }

            Picker("Reasoning effort", selection: $effortSelection) {
                Text("Default").tag("default")
                ForEach(Self.presetLevels, id: \.self) { level in
                    Text(level.capitalized).tag(level)
                }
                Text("Custom").tag("custom")
            }
            .onChange(of: effortSelection) { _, newValue in
                switch newValue {
                case "default":
                    template.reasoningEffort = nil
                case "custom":
                    template.reasoningEffort = customEffort.isEmpty ? nil : customEffort
                default:
                    template.reasoningEffort = newValue
                }
            }
            if effortSelection == "custom" {
                TextField("Custom effort value", text: $customEffort)
                    .onChange(of: customEffort) { _, newValue in
                        template.reasoningEffort = newValue.isEmpty ? nil : newValue
                    }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if effortSelection == "custom", customEffort.isEmpty {
                        template.reasoningEffort = nil
                    }
                    onSave(template)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.isEmpty || template.prompt.isEmpty)
            }
        }
        .frame(width: 420, height: 320)
        .padding()
    }
}
