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

    init() {
        _webSearchEnabled = State(initialValue: CompanionConfigService.searchProviderKind() != "none")
        _commandToolsEnabled = State(initialValue: CompanionConfigService.commandToolsEnabled())
        _githubSearchEnabled = State(initialValue: CompanionConfigService.githubSearchEnabled())
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
                    CommandToolController.registerNotificationCategory()
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
            Text("Tools the model can call on the OpenAI-compatible backend. Toggle a tool to offer or hide it; Configure edits its provider, keys, and defaults. ACP agents bring their own tools.")
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
/// new sessions start from, and where the per-session controls live.
struct CommandRunnerToolSheet: View {
    @State private var defaultWorkingDir: String

    @Environment(\.dismiss) private var dismiss

    init() {
        _defaultWorkingDir = State(initialValue: CompanionConfigService.commandDefaultWorkingDir())
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

            Text("New chat sessions start from this dir; the header in the chat panel shows it and can switch it per session. Read-only commands run without asking, everything else shows a confirmation card, and Auto-run (YOLO) stays per session in the chat header.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460, height: 320)
        .padding()
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