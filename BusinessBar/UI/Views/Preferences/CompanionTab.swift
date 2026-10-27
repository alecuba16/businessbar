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
    @State private var baseURLText: String
    @State private var modelText: String
    @State private var systemPromptText: String
    @State private var apiKeyText: String
    @State private var searchProviderKind: String
    @State private var braveKeyText: String
    @State private var tavilyKeyText: String
    @State private var customSearchEndpointText: String
    @State private var customSearchHeaderNameText: String
    @State private var customSearchKeyText: String
    @State private var acpCommandText: String
    @State private var acpArgumentsText: String
    @State private var reasoningEnabled: Bool
    @State private var reasoningEffort: String
    @State private var customEffortText: String
    @State private var headerPairs: [HeaderPair]
    @State private var historyMaxAgeDays: Int
    @State private var historyMaxSessions: Int
    @State private var templates: [PromptTemplate]
    @State private var editingTemplate: PromptTemplate?
    @State private var showsTemplateEditor = false
    @State private var keychainError: String?
    @State private var profiles: [ModelProfile]
    @State private var editingProfile: ModelProfile?
    @State private var showsProfileEditor = false

    private let templateStore = TemplateStore()

    init() {
        let defaults = UserDefaults.standard
        _backend = State(initialValue: CompanionConfigService.backend())
        _baseURLText = State(initialValue: defaults.string(forKey: Constants.Defaults.companionBaseURL)
            ?? Constants.DefaultValues.companionBaseURL)
        _modelText = State(initialValue: defaults.string(forKey: Constants.Defaults.companionModel)
            ?? Constants.DefaultValues.companionModel)
        _systemPromptText = State(initialValue: defaults.string(forKey: Constants.Defaults.companionSystemPrompt) ?? "")
        _apiKeyText = State(initialValue: CompanionConfigService.apiKey())
        _searchProviderKind = State(initialValue: CompanionConfigService.searchProviderKind())
        _braveKeyText = State(initialValue: CompanionConfigService.braveKey())
        _tavilyKeyText = State(initialValue: CompanionConfigService.tavilyKey())
        _customSearchEndpointText = State(initialValue: defaults.string(forKey: Constants.Defaults.companionCustomSearchEndpoint) ?? "")
        _customSearchHeaderNameText = State(initialValue: CompanionConfigService.customSearchHeaderName())
        _customSearchKeyText = State(initialValue: CompanionConfigService.customSearchKey())
        _acpCommandText = State(initialValue: CompanionConfigService.acpCommand())
        _acpArgumentsText = State(initialValue: CompanionConfigService.acpArguments().joined(separator: " "))
        _reasoningEnabled = State(initialValue: CompanionConfigService.reasoningEnabled())
        let storedEffort = CompanionConfigService.reasoningEffort()
        // Non-preset stored values keep the Custom row selected with the
        // text field carrying the actual string.
        _reasoningEffort = State(initialValue:
            CompanionConfigService.effortLevels.contains(storedEffort) ? storedEffort : "__custom__")
        _customEffortText = State(initialValue: storedEffort)
        _headerPairs = State(initialValue: CompanionConfigService.customHeaders().map {
            HeaderPair(name: $0.name, value: $0.value)
        })
        _historyMaxAgeDays = State(initialValue: CompanionConfigService.historyMaxAgeDays())
        _historyMaxSessions = State(initialValue: CompanionConfigService.historyMaxSessions())
        _templates = State(initialValue: TemplateStore().load())
        _profiles = State(initialValue: CompanionConfigService.modelProfiles())
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

                    if backend == .openai {
                        openAIFields
                    } else {
                        acpFields
                    }
                } header: {
                    Text("Model Backend")
                } footer: {
                    Text(backend == .openai
                        ? "Any OpenAI-compatible endpoint. The API key is stored in the Keychain."
                        : "Runs a local ACP agent over stdio, for example 'gemini --acp' or 'claude --acp'. The process starts with the chat panel and stops when it closes.")
                }

                // MARK: Profiles
                if backend == .openai {
                    Section {
                        ForEach(profiles) { profile in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .fontWeight(.medium)
                                    Text("\(profile.model) · \(profile.baseURL)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if CompanionConfigService.selectedModelProfile()?.id == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .help("Selected for chat")
                                }
                                Button("Edit") {
                                    editingProfile = profile
                                    showsProfileEditor = true
                                }
                                .controlSize(.small)
                                Button {
                                    CompanionConfigService.deleteModelProfile(id: profile.id)
                                    profiles = CompanionConfigService.modelProfiles()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete this profile")
                            }
                        }

                        Button("Add Profile") {
                            editingProfile = nil
                            showsProfileEditor = true
                        }
                    } header: {
                        Text("Model Profiles")
                    } footer: {
                        Text("Named endpoint presets the chat panel can switch between mid-conversation. The profile with the checkmark is the chat default; rewrite templates keep using the backend fields above. Keys are stored in the Keychain per profile.")
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

                // MARK: Templates
                Section {
                    ForEach($templates) { $template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .fontWeight(.medium)
                                if template.autoReplace {
                                    Text("Replaces directly when the reply has output tags")
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
                    Text("Use [placeholder] where the selected text goes. Assign a shortcut to a template to run that rewrite on the selection from any app. Wrap the reply in <output></output> tags in your prompt and only that text is used, with no model commentary. Templates with direct replace skip the overlay and swap the selection in place when the reply carries the tags.")
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
        .sheet(isPresented: $showsProfileEditor) {
            ProfileEditorSheet(profile: editingProfile) { saved, apiKey in
                if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
                    profiles[index] = saved
                } else {
                    profiles.append(saved)
                }
                CompanionConfigService.modelProfileStore.save(profiles)
                if !apiKey.isEmpty {
                    do {
                        try CompanionConfigService.setProfileAPIKey(saved.id, apiKey)
                        keychainError = nil
                    } catch {
                        keychainError = "Could not save the API key: \(error.localizedDescription)"
                    }
                }
                showsProfileEditor = false
            }
        }
    }

    private var openAIFields: some View {
        Group {
            TextField("Base URL (ends in /v1)", text: $baseURLText)
                .onChange(of: baseURLText) { _, newValue in
                    if let url = URL(string: newValue.trimmingCharacters(in: .whitespaces)) {
                        CompanionConfigService.setBaseURL(url)
                    }
                }

            TextField("Model", text: $modelText)
                .onChange(of: modelText) { _, newValue in
                    CompanionConfigService.setModel(newValue)
                }

            SecureField("API Key (stored in Keychain)", text: $apiKeyText)
                .onChange(of: apiKeyText) { _, newValue in
                    do {
                        try CompanionConfigService.setAPIKey(newValue)
                        keychainError = nil
                    } catch {
                        keychainError = "Could not save the API key: \(error.localizedDescription)"
                    }
                }

            if let keychainError {
                Text(keychainError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            TextField("System prompt (optional)", text: $systemPromptText, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: systemPromptText) { _, newValue in
                    CompanionConfigService.setSystemPrompt(newValue)
                }

            Toggle("Reasoning model", isOn: $reasoningEnabled)
                .onChange(of: reasoningEnabled) { _, newValue in
                    CompanionConfigService.setReasoningEnabled(newValue)
                }

            if reasoningEnabled {
                Picker("Reasoning effort", selection: $reasoningEffort) {
                    ForEach(CompanionConfigService.effortLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                    Text("Custom").tag("__custom__")
                }
                .onChange(of: reasoningEffort) { _, newValue in
                    if newValue != "__custom__" {
                        CompanionConfigService.setReasoningEffort(newValue)
                    }
                }
                if reasoningEffort == "__custom__" {
                    TextField("Custom effort value", text: $customEffortText)
                        .onChange(of: customEffortText) { _, newValue in
                            if !newValue.isEmpty {
                                CompanionConfigService.setReasoningEffort(newValue)
                            }
                        }
                }
            }

            ForEach($headerPairs) { $pair in
                HStack {
                    TextField("Header name", text: $pair.name)
                    SecureField("Value", text: $pair.value)
                    Button {
                        headerPairs.removeAll { $0.id == pair.id }
                        saveHeaders()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove header")
                }
                .onChange(of: pair.name) { _, _ in saveHeaders() }
                .onChange(of: pair.value) { _, _ in saveHeaders() }
            }

            Button("Add Header") {
                headerPairs.append(HeaderPair(name: "", value: ""))
                saveHeaders()
            }

            if !isConfigured {
                Text("Enter an API key to use the companion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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

    private func saveHeaders() {
        let pairs = headerPairs
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
        try? CompanionConfigService.setCustomHeaders(pairs)
    }

    private var isConfigured: Bool {
        !modelText.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKeyText.isEmpty
    }
}

// MARK: - HeaderPair

/// Editable row for one custom request header.
private struct HeaderPair: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

// MARK: - ProfileEditorSheet

/// Sheet for creating and editing a model profile: name, endpoint, model,
/// default reasoning effort, and the per-profile API key.
struct ProfileEditorSheet: View {
    @State private var profile: ModelProfile
    @State private var apiKey: String
    let onSave: (ModelProfile, String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(profile: ModelProfile?, onSave: @escaping (ModelProfile, String) -> Void) {
        let initial = profile ?? ModelProfile(name: "", baseURL: "", model: "")
        _profile = State(initialValue: initial)
        _apiKey = State(initialValue: CompanionConfigService.profileAPIKey(id: initial.id))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.name.isEmpty ? "New Profile" : "Edit Profile")
                .font(.headline)

            TextField("Name", text: $profile.name)
            TextField("Base URL (ends in /v1)", text: $profile.baseURL)
            TextField("Model", text: $profile.model)
            SecureField("API Key (stored in Keychain)", text: $apiKey)

            Picker("Default effort", selection: Binding(
                get: { profile.reasoningEffort ?? "" },
                set: { profile.reasoningEffort = $0.isEmpty ? nil : $0 }
            )) {
                Text("Global default").tag("")
                ForEach(CompanionConfigService.effortLevels, id: \.self) { level in
                    Text(level.capitalized).tag(level)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(profile, apiKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.isEmpty || profile.model.isEmpty || profile.baseURL.isEmpty)
            }
        }
        .frame(width: 420, height: 280)
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

            Toggle("Replace directly when the reply has output tags", isOn: $template.autoReplace)

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
