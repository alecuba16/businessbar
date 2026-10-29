import AppKit
import BusinessBarCore
import Foundation
import UserNotifications

// MARK: - CommandApprovalRequest

/// One pending confirmation card in the chat stream. The continuation
/// resumes when the user picks Allow once, Always this session, or Deny,
/// or when the 5-minute timeout denies it.
struct CommandApprovalRequest: Identifiable {
    enum Decision: Sendable {
        case allowOnce
        case alwaysThisSession
        /// Persists an allow prefix rule; offered on the card so repeat
        /// commands stop asking across sessions too.
        case alwaysAllowPersistent
        case denied
    }

    let id = UUID()
    let command: String
    let reason: CommandRisk
    /// Risk class and non-flag targets, for the card's detail line.
    let category: CommandCategory
    let targets: [String]
    let workspaceRoot: String
    let completion: @MainActor (Decision) -> Void
}

// MARK: - BackgroundProcessCard

/// A background command surfaced in the chat stream: handle, command,
/// live status, and a Stop button that works while the stream is idle.
struct BackgroundProcessSnapshot: Identifiable, Equatable {
    let id: UUID
    let command: String
    let running: Bool
    let exitCode: Int32?
    let endedReason: String?
}

// MARK: - CommandToolController

/// Glue between the LLM tool loop and the command stack. Owned by the
/// panel controller next to ChatStore, one per chat panel.
///
/// The handler passed via `onToolCall` runs on the stream task, so it
/// never blocks UI: approvals suspend on a continuation until the user
/// decides, and command execution awaits the registry actor.
@MainActor
final class CommandToolController: ObservableObject {
    @Published var approvalRequest: CommandApprovalRequest?
    @Published var backgroundProcesses: [BackgroundProcessSnapshot] = []
    @Published var workspaceRoot: String?
    /// run_command activation for this session, seeded from the Preferences
    /// default and reset when the session ends. Allow skips the card for
    /// anything but the deny-wins set, deny refuses every call.
    @Published var sessionPermissionMode: CommandPermissionMode

    /// Workspace commands actually run in: the picked folder, the default
    /// from Preferences, or the user home, in that order, so command tools
    /// work before any pick.
    var effectiveWorkspaceRoot: String {
        workspaceRoot
            ?? CompanionConfigService.commandDefaultWorkingDir()
    }

    /// Approved Tier 1 prefix rules for this session, built from "Always
    /// this session" decisions. Never persisted.
    private var sessionPrefixes: [String] = []
    /// IUO so init can build the registry with a closure that captures
    /// self: optional stored properties default to nil before phase 1 ends.
    private var registry: BackgroundCommandRegistry!

    init() {
        sessionPermissionMode = CompanionConfigService.commandPermissionMode()
        registry = BackgroundCommandRegistry(
            onExit: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Refresh the live card first so a visible panel reflects
                    // the exit, then notify only if the user is elsewhere.
                    await self.refreshBackgroundProcesses()
                    self.postCompletionNotification(command: result.command, exitCode: result.exitCode)
                }
            }
        )
    }
    private var sessionID: UUID?
    /// Panel visibility gate for completion notifications.
    var isPanelVisible: () -> Bool = { false }

    // MARK: - Session lifecycle

    func beginSession(_ id: UUID?) {
        // A continuation left over from the previous conversation must not
        // leak into this one.
        denyPendingApproval()
        sessionID = id
        // Loading an old conversation is a session switch too: the mode
        // from the chat the user just left must not carry over.
        sessionPermissionMode = CompanionConfigService.commandPermissionMode()
    }

    func endSession() {
        denyPendingApproval()
        sessionID = nil
        sessionPrefixes = []
        // The activation mode is session-scoped like the workspace folder:
        // each new conversation starts from the Preferences default.
        sessionPermissionMode = CompanionConfigService.commandPermissionMode()
        workspaceRoot = nil
        Task { await refreshBackgroundProcesses() }
    }

    // MARK: - Approval

    func decide(_ decision: CommandApprovalRequest.Decision) {
        guard let request = approvalRequest else { return }
        approvalRequest = nil
        switch decision {
        case .alwaysThisSession:
            // The full command becomes a Tier 1 prefix rule: the exact
            // command and anything extending it as new arguments.
            sessionPrefixes.append(request.command)
        case .alwaysAllowPersistent:
            var prefixes = CompanionConfigService.commandAllowedPrefixes()
            if !prefixes.contains(request.command) {
                prefixes.append(request.command)
                CompanionConfigService.setCommandAllowedPrefixes(prefixes)
            }
        case .allowOnce, .denied:
            break
        }
        request.completion(decision)
    }

    private func classifyForApproval(_ command: String) -> CommandPermission {
        CommandPermissionParser.classify(command, sessionPrefixes: sessionPrefixes)
    }

    /// Suspends until the user decides, panel closes (deny), or the
    /// 5-minute timeout denies.
    private func requestApproval(
        command: String,
        reason: CommandRisk,
        category: CommandCategory,
        targets: [String]
    ) async -> CommandApprovalRequest.Decision {
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<CommandApprovalRequest.Decision, Never>) in
            let root = effectiveWorkspaceRoot
            let request = CommandApprovalRequest(
                command: command,
                reason: reason,
                category: category,
                targets: targets,
                workspaceRoot: root,
                completion: { decision in
                    continuation.resume(returning: decision)
                }
            )
            approvalRequest = request

            // Auto-deny on timeout: no silent window left open.
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if approvalRequest?.id == request.id {
                    approvalRequest = nil
                    continuation.resume(returning: .denied)
                }
            }
        }
        return decision
    }

    /// Deny without an answer. Called when the panel closes or the stream
    /// cancels so no continuation stays suspended.
    func denyPendingApproval() {
        if let request = approvalRequest {
            approvalRequest = nil
            request.completion(.denied)
        }
    }

    // MARK: - Background card refresh

    private func refreshBackgroundProcesses() async {
        backgroundProcesses = await registry.listBackground(sessionID: sessionID).map {
            BackgroundProcessSnapshot(
                id: $0.handle,
                command: $0.command,
                running: $0.running,
                exitCode: $0.exitCode,
                endedReason: $0.endedReason
            )
        }
    }

    func stopBackgroundProcess(_ handle: UUID) async {
        _ = await registry.stop(handle)
        await refreshBackgroundProcesses()
    }

    // MARK: - Tool handler

    /// The onToolCall handler for the whole panel: command tools route
    /// here, web_search falls through to the configured search provider.
    /// `stream(onToolCall:)` replaces the client's stored handler, so one
    /// entry point must cover both.
    func makePanelToolHandler() -> ((String, String) async -> String)? {
        guard CompanionConfigService.commandToolsEnabled(),
              CompanionConfigService.selectedACPProvider() == nil
        else { return nil }
        let searchHandler = CompanionConfigService.searchToolHandler()
        let controller = self
        return { name, argumentsJSON in
            if name == "web_search" || name == "github_search" {
                return await searchHandler?(name, argumentsJSON)
                    ?? "Error: \(name) is not configured"
            }
            return await controller.handleToolCall(name: name, argumentsJSON: argumentsJSON)
        }
    }

    /// Returns the tool result string for the model.
    func handleToolCall(name: String, argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return "error: could not parse tool arguments"
        }

        switch name {
        case "run_command":
            return await runCommand(json)
        case "read_file":
            return readFile(json)
        case "list_files":
            return listFiles(json)
        case "list_background_processes":
            return await listBackgroundProcesses()
        case "read_background_output":
            return await readBackgroundOutput(json)
        case "stop_background_process":
            return await stopBackgroundProcess(json)
        default:
            return "error: unknown tool \(name)"
        }
    }

    private func runCommand(_ json: [String: Any]) async -> String {
        guard let (command, background) = CommandToolCatalog.decodeRunCommandArguments(json) else {
            return "error: run_command needs a command string"
        }
        guard !effectiveWorkspaceRoot.isEmpty else {
            return "error: no workspace folder selected. Ask the user to pick one in the panel header."
        }
        let root = effectiveWorkspaceRoot

        let resolved = CommandPermissionParser.resolve(
            command,
            sessionPrefixes: sessionPrefixes,
            mode: sessionPermissionMode,
            settings: CompanionConfigService.commandPermissionSettings()
        )
        if resolved.refused {
            let hint: String
            if resolved.category == .fileDelete,
               CompanionConfigService.commandCategoryMode(.fileDelete) == .deny {
                hint = " File deletion is set to Deny in Preferences."
            } else {
                hint = ""
            }
            return "denied: command runner refused this command for this session.\(hint)"
        }
        var permission = resolved.permission

        let argv: [String]
        switch permission {
        case .autoApproved(let resolvedArgv):
            argv = resolvedArgv
        case .sessionApproved:
            argv = ShellExecutor.argv(for: permission, command: command)
        case .needsConfirmation(let reason):
            let decision = await requestApproval(
                command: command,
                reason: reason,
                category: resolved.category,
                targets: CommandPermissionParser.categorize(command).targets
            )
            guard decision != .denied else {
                return "denied by user"
            }
            argv = ShellExecutor.argv(for: .sessionApproved(command: command), command: command)
        }

        if background {
            do {
                let info = try await registry.runBackground(
                    sessionID: sessionID,
                    command: command,
                    argv: argv,
                    cwd: root
                )
                await refreshBackgroundProcesses()
                let status = info.running ? "running" : "exited(\(info.exitCode ?? -1))"
                return "started in background. handle: \(info.handle.uuidString), status: \(status)"
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }

        do {
            let outcome = try await registry.runForeground(
                sessionID: sessionID,
                command: command,
                argv: argv,
                cwd: root
            )
            switch outcome {
            case .exited(let code, let output):
                return "exit code \(code)\n\(output)"
            case .promoted(let handle, let partial):
                await refreshBackgroundProcesses()
                return "command still running after timeout, moved to background. handle: \(handle.uuidString)\npartial output:\n\(partial)"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    private func readFile(_ json: [String: Any]) -> String {
        let (path, offset, limit) = CommandToolCatalog.decodeReadFileArguments(json)
        guard !effectiveWorkspaceRoot.isEmpty else {
            return "error: no workspace folder selected. Ask the user to pick one in the panel header."
        }
        let root = effectiveWorkspaceRoot
        guard let absolute = WorkspacePathGuard.resolve(path, root: root) else {
            return "error: path is outside the workspace folder"
        }
        guard FileManager.default.fileExists(atPath: absolute) else {
            return "error: file not found: \(path)"
        }
        guard let content = try? String(contentsOfFile: absolute, encoding: .utf8) else {
            return "error: file is not valid UTF-8 text"
        }
        let lines = content.components(separatedBy: "\n")
        guard offset <= lines.count else { return "" }
        let slice = lines[(offset - 1)...].prefix(limit)
        return slice.joined(separator: "\n")
    }

    private func listFiles(_ json: [String: Any]) -> String {
        let (path, recursive) = CommandToolCatalog.decodeListFilesArguments(json)
        guard !effectiveWorkspaceRoot.isEmpty else {
            return "error: no workspace folder selected. Ask the user to pick one in the panel header."
        }
        let root = effectiveWorkspaceRoot
        guard let absolute = WorkspacePathGuard.resolve(path, root: root) else {
            return "error: path is outside the workspace folder"
        }
        guard FileManager.default.fileExists(atPath: absolute) else {
            return "error: folder not found: \(path)"
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return "error: not a folder: \(path)"
        }

        let fm = FileManager.default
        if recursive {
            // Bounded walk: skip hidden entries and stop past 5000 lines
            // so a huge tree never floods the context.
            var out: [String] = []
            var queue = [absolute]
            while let dir = queue.popLast(), out.count < 5_000 {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries.sorted() where !entry.hasPrefix(".") {
                    let full = (dir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let relative = String(full.dropFirst(root.count + 1))
                    out.append(isDir.boolValue ? relative + "/" : relative)
                    if isDir.boolValue { queue.append(full) }
                }
            }
            return out.joined(separator: "\n")
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: absolute) else {
            return "error: could not read folder"
        }
        return entries
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { entry in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: (absolute as NSString).appendingPathComponent(entry), isDirectory: &isDir)
                return isDir.boolValue ? entry + "/" : entry
            }
            .joined(separator: "\n")
    }

    private func listBackgroundProcesses() async -> String {
        await refreshBackgroundProcesses()
        guard !backgroundProcesses.isEmpty else { return "no background processes" }
        return backgroundProcesses
            .map { entry in
                let status = entry.running
                    ? "running"
                    : "exited(\(entry.exitCode ?? -1)) \(entry.endedReason ?? "")".trimmingCharacters(in: .whitespaces)
                return "\(entry.id.uuidString)  \(entry.command)  \(status)"
            }
            .joined(separator: "\n")
    }

    private func readBackgroundOutput(_ json: [String: Any]) async -> String {
        let (handleString, lines) = CommandToolCatalog.decodeReadBackgroundArguments(json)
        guard let handle = UUID(uuidString: handleString) else {
            return "error: invalid handle"
        }
        guard let output = await registry.output(handle, lines: lines) else {
            return "error: process no longer exists (it may be from a previous app run)"
        }
        return output
    }

    private func stopBackgroundProcess(_ json: [String: Any]) async -> String {
        guard let handleString = CommandToolCatalog.decodeStopArguments(json),
              let handle = UUID(uuidString: handleString)
        else {
            return "error: invalid handle"
        }
        let didStop = await registry.stop(handle)
        await refreshBackgroundProcesses()
        return didStop ? "stopped" : "error: process not found or already exited"
    }

    // MARK: - Registry plumbing

    /// Results finished since the last request. ChatStore folds them into
    /// the conversation before the next one.
    func drainPendingResults() async -> [BackgroundCommandRegistry.CompletedResult] {
        await registry.drainPending(sessionID: sessionID)
    }

    /// App quit: kill every child and resolve suspended approvals.
    func shutdown() async {
        denyPendingApproval()
        await registry.sweep()
    }

    // MARK: - Workspace picker

    func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Commands will only run inside this folder."
        panel.prompt = "Choose Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceRoot = url.path
    }

    // MARK: - Notifications

    /// Registers the command-completion category. Call once when the tool
    /// is first enabled, alongside the authorization request.
    static func registerNotificationCategory() {
        let category = UNNotificationCategory(
            identifier: "companion.backgroundCommand",
            actions: [],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func postCompletionNotification(command: String, exitCode: Int32) {
        guard !isPanelVisible() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Background command finished"
        content.body = "\(command)\nexit code \(exitCode)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "companion.backgroundCommand.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}