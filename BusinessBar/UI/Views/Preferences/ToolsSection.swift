import BusinessBarCore
import SwiftUI

// MARK: - ToolsSection

/// Built-in tools with a toggle and a Configure sheet each. Tools are
/// provided by the app, never removable: disabling hides them from the
/// model, configuring edits their credentials and behavior.
struct ToolsSection: View {
    @State private var webSearchEnabled: Bool
    @State private var commandToolsEnabled: Bool
    @State private var githubSearchEnabled: Bool
    @State private var showsWebSearchSheet = false
    @State private var showsCommandSheet = false
    @State private var showsGitHubSheet = false
    /// Test seam: the command-runner toggle registers its notification
    /// category when turning on; the fixture injects a recorded no-op so
    /// the real notification center is never touched. Default keeps the
    /// production registration exactly.
    @MainActor private let registerNotificationCategory: () -> Void

    init(
        registerNotificationCategory: @escaping @MainActor () -> Void = {
            CommandToolController.registerNotificationCategory()
        }
    ) {
        _webSearchEnabled = State(initialValue: CompanionConfigService.searchProviderKind() != "none")
        _commandToolsEnabled = State(initialValue: CompanionConfigService.commandToolsEnabled())
        _githubSearchEnabled = State(initialValue: CompanionConfigService.githubSearchEnabled())
        self.registerNotificationCategory = registerNotificationCategory
    }

    var body: some View {
        Section {
            toolRow(
                name: "Web Search",
                caption: webSearchCaption,
                enabled: $webSearchEnabled,
                onConfigure: { showsWebSearchSheet = true }
            ) { newValue in
                CompanionConfigService.setSearchProviderKind(
                    newValue ? CompanionConfigService.lastSearchProviderKind() : "none"
                )
            }

            toolRow(
                name: "Command Runner",
                caption: "run_command, read_file, list_files",
                enabled: $commandToolsEnabled,
                onConfigure: { showsCommandSheet = true }
            ) { enabled in
                CompanionConfigService.setCommandToolsEnabled(enabled)
                if enabled {
                    // AppDelegate owns the notification delegate and
                    // already asked for authorization at launch.
                    registerNotificationCategory()
                }
            }

            toolRow(
                name: "GitHub Code Search",
                caption: githubSearchCaption,
                enabled: $githubSearchEnabled,
                onConfigure: { showsGitHubSheet = true }
            ) { enabled in
                CompanionConfigService.setGitHubSearchEnabled(enabled)
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Tools the model can call. Toggle a tool to offer or hide it; Configure edits its provider, keys, and defaults. ACP agents bring their own tools.")
        }
        .sheet(isPresented: $showsWebSearchSheet) {
            WebSearchToolSheet()
        }
        .sheet(isPresented: $showsCommandSheet) {
            CommandRunnerToolSheet()
        }
        .sheet(isPresented: $showsGitHubSheet) {
            GitHubSearchToolSheet()
        }
    }

    private var webSearchCaption: String {
        switch CompanionConfigService.searchProviderKind() {
        case "none": return "off"
        case "scrape-ddg": return "DuckDuckGo"
        case "scrape-bing": return "Bing"
        case "scrape-google-news": return "Google News"
        case "brave": return "Brave"
        case "tavily": return "Tavily"
        case "custom": return "Custom endpoint"
        default: return "off"
        }
    }

    private var githubSearchCaption: String {
        CompanionConfigService.githubSearchKey().isEmpty ? "add a token in Configure" : "token set"
    }

    /// One built-in tool row: name, caption, toggle, Configure button.
    private func toolRow(
        name: String,
        caption: String,
        enabled: Binding<Bool>,
        onConfigure: @escaping () -> Void,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.medium)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: enabled)
                .labelsHidden()
                .onChange(of: enabled.wrappedValue) { _, newValue in
                    onToggle(newValue)
                }
            Button("Configure…") {
                onConfigure()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - WebSearchToolSheet

/// Web search configuration: provider picker, per-provider key fields, and
/// the full custom endpoint treatment (URL template plus header pairs).
struct WebSearchToolSheet: View {
    @State private var providerKind: String
    @State private var braveKeyText: String
    @State private var tavilyKeyText: String
    @State private var customEndpointText: String
    @State private var customHeaders: [EditableHeaderPair]

    @Environment(\.dismiss) private var dismiss

    init() {
        _providerKind = State(initialValue: CompanionConfigService.searchProviderKind() == "none"
            ? CompanionConfigService.lastSearchProviderKind()
            : CompanionConfigService.searchProviderKind())
        _braveKeyText = State(initialValue: CompanionConfigService.braveKey())
        _tavilyKeyText = State(initialValue: CompanionConfigService.tavilyKey())
        _customEndpointText = State(initialValue: UserDefaults.standard
            .string(forKey: Constants.Defaults.companionCustomSearchEndpoint) ?? "")
        _customHeaders = State(initialValue: CompanionConfigService.customSearchHeaders().map {
            EditableHeaderPair(name: $0.name, value: $0.value)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Web Search")
                .font(.headline)

            Picker("Provider", selection: $providerKind) {
                Text("DuckDuckGo (scraped)").tag("scrape-ddg")
                Text("Bing (scraped)").tag("scrape-bing")
                Text("Google News (scraped)").tag("scrape-google-news")
                Text("Brave (API key)").tag("brave")
                Text("Tavily (API key)").tag("tavily")
                Text("Custom endpoint").tag("custom")
            }
            .onChange(of: providerKind) { _, newValue in
                CompanionConfigService.setSearchProviderKind(newValue)
            }

            switch providerKind {
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
                TextField("URL, e.g. https://host/search?q={query}&count={count}", text: $customEndpointText)
                    .onChange(of: customEndpointText) { _, newValue in
                        CompanionConfigService.setCustomSearchEndpointText(
                            newValue.trimmingCharacters(in: .whitespaces)
                        )
                    }

                if !customEndpointText.contains("{query}") {
                    Text("No {query} in the URL: the endpoint is used in the legacy POST mode with a JSON body {query, max_results}.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach($customHeaders) { $pair in
                    HStack {
                        TextField("Header name", text: $pair.name)
                        SecureField("Value", text: $pair.value)
                        Button {
                            customHeaders.removeAll { $0.id == pair.id }
                            persistHeaders()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove header")
                    }
                }
                Button("Add Header") {
                    customHeaders.append(EditableHeaderPair(name: "", value: ""))
                }

                Text("Put {query} in the URL for GET mode; headers ride along with every request and their values live in the Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            default:
                Text("Scraped engines need no key and fall back to each other when one blocks the request.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460, height: 380)
        .padding()
    }

    /// Saves the header list on every edit so a crash or quit mid-edit
    /// loses nothing; mirrors how the key fields persist on change.
    private func persistHeaders() {
        let trimmed = customHeaders
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
        try? CompanionConfigService.setCustomSearchHeaders(trimmed)
    }
}

// MARK: - CommandRunnerToolSheet

/// Command runner configuration: the tool list, the default working dir
/// new sessions start from, per-category permission dials, and persistent
/// allow/deny prefix rules.
struct CommandRunnerToolSheet: View {
    @State private var defaultWorkingDir: String
    @State private var defaultMode: CommandPermissionMode
    @State private var categoryModes: [CommandCategory: CommandPermissionMode]
    @State private var allowedPrefixes: [String]
    @State private var deniedPrefixes: [String]
    @State private var newAllowRule = ""
    @State private var newDenyRule = ""

    @Environment(\.dismiss) private var dismiss

    init() {
        _defaultWorkingDir = State(initialValue: CompanionConfigService.commandDefaultWorkingDir())
        _defaultMode = State(initialValue: CompanionConfigService.commandPermissionMode())
        var modes: [CommandCategory: CommandPermissionMode] = [:]
        for category in CommandCategory.allCases {
            if let mode = CompanionConfigService.commandCategoryMode(category) {
                modes[category] = mode
            }
        }
        _categoryModes = State(initialValue: modes)
        _allowedPrefixes = State(initialValue: CompanionConfigService.commandAllowedPrefixes())
        _deniedPrefixes = State(initialValue: CompanionConfigService.commandDeniedPrefixes())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Command Runner")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tools offered to the model:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach([
                    "run_command: shell command, background option with a handle",
                    "read_file: file contents from the working dir",
                    "list_files: directory listing from the working dir",
                    "list_background_processes / read_background_output: track background runs"
                ], id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default working dir:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text((defaultWorkingDir as NSString).lastPathComponent)
                        .lineLimit(1)
                        .help(defaultWorkingDir)
                }
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    defaultWorkingDir = url.path
                    CompanionConfigService.setCommandDefaultWorkingDir(url.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Choose default working dir")
            }

            Picker("run_command", selection: $defaultMode) {
                Text("Ask").tag(CommandPermissionMode.ask)
                Text("Allow").tag(CommandPermissionMode.allow)
                Text("Deny").tag(CommandPermissionMode.deny)
            }
            .pickerStyle(.segmented)
            .onChange(of: defaultMode) { _, newValue in
                CompanionConfigService.setCommandPermissionMode(newValue)
            }
            Text("Default activation for run_command in new sessions: Allow runs commands without asking, Ask confirms anything beyond read-only commands, Deny refuses every call. The chat header can switch it per session, and Allow still prompts for rm and credentials files. read_file and list_files never ask.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Per-category defaults")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    categoryRow(category)
                }
                Text("A category dial overrides the session mode above for the commands it classifies into. Read-only follows the session mode unless you pin it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ruleEditor(
                title: "Always allow",
                rules: $allowedPrefixes,
                newRule: $newAllowRule,
                placeholder: "Prefix rule, e.g. git status or npm test *",
                onSave: { CompanionConfigService.setCommandAllowedPrefixes($0) }
            )
            ruleEditor(
                title: "Always deny",
                rules: $deniedPrefixes,
                newRule: $newDenyRule,
                placeholder: "Prefix rule, e.g. curl *",
                onSave: { CompanionConfigService.setCommandDeniedPrefixes($0) }
            )
            Text("Prefix rules match the exact command or any command starting with it; a trailing * marks a wildcard. Deny wins over allow. Rules persist across sessions; \"Always Allow\" on the approval card adds here.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("New chat sessions start from this dir; the header in the chat panel shows it and can switch it per session.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460, height: 640)
        .padding()
    }

    /// One category dial row: title, session-mode follow note, and a
    /// three-way picker (Ask/Allow/Deny) with a default position.
    private func categoryRow(_ category: CommandCategory) -> some View {
        HStack {
            Text(category.title)
                .font(.caption)
            Spacer()
            if let mode = categoryModes[category] {
                Picker("", selection: Binding(
                    get: { mode },
                    set: { newValue in
                        categoryModes[category] = newValue
                        CompanionConfigService.setCommandCategoryMode(newValue, for: category)
                    }
                )) {
                    ForEach(CommandPermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 160)
                Button {
                    categoryModes[category] = nil
                    CompanionConfigService.setCommandCategoryMode(nil, for: category)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Follow the session mode")
            } else {
                Picker("", selection: Binding(
                    get: { categoryModes[category] },
                    set: { newValue in
                        categoryModes[category] = newValue
                        CompanionConfigService.setCommandCategoryMode(newValue, for: category)
                    }
                )) {
                    Text("Session mode").tag(Optional<CommandPermissionMode>.none)
                    ForEach(CommandPermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(Optional(mode))
                    }
                }
                .controlSize(.small)
                .frame(width: 160)
            }
        }
    }

    /// Allow/deny rule list with add/remove and direct persistence.
    private func ruleEditor(
        title: String,
        rules: Binding<[String]>,
        newRule: Binding<String>,
        placeholder: String,
        onSave: @escaping ([String]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(rules.wrappedValue.indices, id: \.self) { index in
                HStack {
                    Text(rules.wrappedValue[index])
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        rules.wrappedValue.remove(at: index)
                        onSave(rules.wrappedValue)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                }
            }
            HStack {
                TextField(placeholder, text: newRule)
                    .onSubmit { addRule(to: rules, newRule: newRule, onSave: onSave) }
                Button("Add") {
                    addRule(to: rules, newRule: newRule, onSave: onSave)
                }
                .controlSize(.small)
                .disabled(newRule.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addRule(
        to rules: Binding<[String]>,
        newRule: Binding<String>,
        onSave: @escaping ([String]) -> Void
    ) {
        let trimmed = newRule.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rules.wrappedValue.contains(trimmed) else { return }
        rules.wrappedValue.append(trimmed)
        onSave(rules.wrappedValue)
        newRule.wrappedValue = ""
    }
}

// MARK: - GitHubSearchToolSheet

/// GitHub code search configuration: token field with the creation link
/// and the endpoint's rate limit spelled out.
struct GitHubSearchToolSheet: View {
    @State private var tokenText: String

    @Environment(\.dismiss) private var dismiss

    init() {
        _tokenText = State(initialValue: CompanionConfigService.githubSearchKey())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Code Search")
                .font(.headline)

            SecureField("Personal access token", text: $tokenText)
                .onChange(of: tokenText) { _, newValue in
                    try? CompanionConfigService.setGitHubSearchKey(newValue)
                }

            HStack(spacing: 4) {
                Text("No token yet?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("Create a fine-grained token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .font(.caption)
                Text("(public code search needs no permissions; private repos need code read access).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("The github_search tool searches code across repositories the token can see. GitHub allows 10 search requests per minute, so the model sees results capped at 5 per query. The tool is only offered while it is toggled on and a token is stored.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460, height: 240)
        .padding()
    }
}
