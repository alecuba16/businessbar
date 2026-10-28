import Foundation

// MARK: - CommandRisk

/// Why a command needs confirmation, in plain words for the approval card.
public enum CommandRisk: Sendable, Equatable {
    /// Writes files, deletes, installs, or otherwise changes state.
    case modifiesFiles
    /// Not on the read-only allowlist.
    case unknownCommand
    /// Combines multiple commands with && || ; | & or newlines.
    case compound
    /// Contains $(), backticks, or process substitution.
    case substitution
    /// Redirection or a pipe, needs a shell to make sense.
    case shellSyntax
    /// Long command, review it fully before running.
    case tooLong
    /// Could not be split into tokens safely.
    case unparseable

    public var label: String {
        switch self {
        case .modifiesFiles: return "writes files or changes state"
        case .unknownCommand: return "not a known read-only command"
        case .compound: return "runs multiple commands"
        case .substitution: return "runs embedded command substitutions"
        case .shellSyntax: return "uses shell redirection or pipes"
        case .tooLong: return "long command"
        case .unparseable: return "could not be parsed safely"
        }
    }
}

// MARK: - CommandPermission

/// How a model-requested command may run.
public enum CommandPermission: Sendable, Equatable {
    /// Read-only allowlisted binary, run as argv without a shell.
    case autoApproved(argv: [String])
    /// Every compound segment matches a session-approved prefix rule.
    case sessionApproved(command: String)
    /// Everything else: runs only after the user confirms.
    case needsConfirmation(reason: CommandRisk)

    public static func == (lhs: CommandPermission, rhs: CommandPermission) -> Bool {
        switch (lhs, rhs) {
        case (.autoApproved(let a), .autoApproved(let b)): return a == b
        case (.sessionApproved(let a), .sessionApproved(let b)): return a == b
        case (.needsConfirmation(let a), .needsConfirmation(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - CommandPermissionParser

/// Classifies a model-supplied command string into a permission tier.
///
/// Tier 0 is the only auto-approve path and it never touches a shell: the
/// string must tokenize into plain argv (no operators, no substitutions, no
/// glob or tilde or variable expansion) and the first token must resolve to
/// an allowlisted read-only binary. Compound splitting is the relaxation
/// gate for session prefix rules, never a reason to auto-approve.
public struct CommandPermissionParser: Sendable {
    /// Read-only binaries, matched on the resolved binary name after a
    /// PATH lookup. `git` additionally restricts to read-only subcommands.
    public static let allowlist: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "find", "wc", "which",
        "diff", "stat", "du", "file", "tree", "rg", "pwd", "echo", "git",
    ]

    /// git subcommands that never write.
    static let gitReadOnlySubcommands: Set<String> = ["status", "log", "diff", "show"]

    /// Flags that turn a nominally read-only command into one that writes
    /// files or runs commands: find -exec family and -delete/-fls/-fprint*,
    /// ripgrep --pre (runs a preprocessor command), git/diff --output
    /// (writes to a file), git --pager (runs a pager command). Exact
    /// matches or `--flag=value` forms only: `--pre` must not swallow
    /// read-only git `--pretty`.
    static func hasWriteFlag(_ argv: [String]) -> Bool {
        let exactFlags: Set<String> = [
            "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls",
            "--output", "--pre", "--pager",
        ]
        for token in argv.dropFirst() {
            if exactFlags.contains(token) { return true }
            if token.hasPrefix("-fprint") { return true }
            if token.hasPrefix("--output=") { return true }
            if token.hasPrefix("--pre=") { return true }
            if token.hasPrefix("--pager=") { return true }
        }
        return false
    }

    /// Wrapper commands (timeout, nice, nohup, env) intentionally do not
    /// reach Tier 0: their first token is not allowlisted, so they always
    /// confirm. Stripping wrappers to auto-approve the inner command is
    /// fragile (each wrapper has its own flag grammar) and the failure
    /// mode is a silent permission bypass.

    /// Commands longer than this always confirm so the user can review them.
    public static let maxAutoApproveLength = 10_000

    // MARK: Tokenizing

    /// Splits a command into argv tokens, honoring single and double
    /// quotes. Returns nil when quoting is unbalanced; callers confirm
    /// rather than guess.
    public static func tokenize(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character? = nil
        var index = command.startIndex

        while index < command.endIndex {
            let ch = command[index]

            if let open = quote {
                if ch == open {
                    quote = nil
                } else {
                    current.append(ch)
                }
                index = command.index(after: index)
                continue
            }

            if ch == "'" || ch == "\"" {
                quote = ch
                hasCurrent = true
                index = command.index(after: index)
                continue
            }

            if ch == " " || ch == "\t" || ch == "\n" {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                index = command.index(after: index)
                continue
            }

            current.append(ch)
            hasCurrent = true
            index = command.index(after: index)
        }

        if quote != nil { return nil }
        if hasCurrent { tokens.append(current) }
        return tokens.isEmpty ? nil : tokens
    }

    /// True when the token list needs a shell for comparison purposes:
    /// glob or expansion metacharacters inside tokens. Conservative by
    /// design; the precise gate is hasShellExpansion on the raw string.
    static func needsShell(_ tokens: [String]) -> Bool {
        for token in tokens {
            if token.contains("*") { return true }
            if token.contains("?") { return true }
            if token.contains("~") { return true }
            if token.contains("$") { return true }
        }
        return false
    }

    /// True when the raw command needs a shell to behave as written.
    /// Shell-exact: globs (* ?) expand only outside quotes, variable and
    /// backslash expansion is suppressed by single quotes and active in
    /// double quotes, and tilde expands only at the start of a word, so
    /// `find . -name '*.swift'` and `git diff HEAD~1` stay shell-free
    /// while `cat *.txt` and `echo "$HOME"` do not.
    public static func hasShellExpansion(_ command: String) -> Bool {
        var quote: Character? = nil
        var previous: Character? = nil
        for ch in command {
            if let open = quote {
                if ch == open {
                    quote = nil
                    previous = ch
                    continue
                }
                // Inside double quotes, variables and backslash escapes
                // still expand in a real shell.
                if open == "\"" && (ch == "$" || ch == "\\") {
                    return true
                }
                previous = ch
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
            case "*", "?":
                return true
            case "$", "\\":
                return true
            case "~":
                // Tilde expands only at the start of a word, so HEAD~1 is
                // a literal but ~/Documents is an expansion.
                if previous == nil || previous == " " || previous == "\t" {
                    return true
                }
            default:
                break
            }
            previous = ch
        }
        return false
    }

    // MARK: Compound splitting

    /// Splits on compound operators outside quotes: && || ; | & and
    /// newlines. Returns nil when quoting is unbalanced.
    public static func splitCompounds(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var quote: Character? = nil
        var index = command.startIndex

        while index < command.endIndex {
            let ch = command[index]

            if let open = quote {
                current.append(ch)
                if ch == open { quote = nil }
                index = command.index(after: index)
                continue
            }

            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                index = command.index(after: index)
                continue
            }

            if ch == "\n" || ch == ";" {
                segments.append(current)
                current = ""
                index = command.index(after: index)
                continue
            }

            if ch == "&" || ch == "|" {
                let next = command.index(after: index)
                if next < command.endIndex && command[next] == ch {
                    // && or ||
                    segments.append(current)
                    current = ""
                    index = command.index(after: next)
                } else {
                    // Single & or |: still a boundary.
                    segments.append(current)
                    current = ""
                    index = next
                }
                continue
            }

            current.append(ch)
            index = command.index(after: index)
        }

        if quote != nil { return nil }
        segments.append(current)

        let cleaned = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// True when the command contains any compound operator or redirection
    /// outside quotes. Single & and | count; parens count too since a
    /// subshell needs the shell.
    public static func containsShellOperator(_ command: String) -> Bool {
        var quote: Character? = nil
        for ch in command {
            if let open = quote {
                if ch == open { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
            case "&", "|", ";", "\n", ">", "<", "(", ")":
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: Binary resolution

    /// Resolves a bare binary name to an absolute path via PATH lookup, or
    /// nil when it is not found. No shell involved.
    public static func resolveBinary(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Classification

    /// Main entry: classify a command string against the session's approved
    /// prefix rules.
    public static func classify(
        _ command: String,
        sessionPrefixes: [String] = []
    ) -> CommandPermission {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .needsConfirmation(reason: .unparseable)
        }
        guard trimmed.count <= maxAutoApproveLength else {
            return .needsConfirmation(reason: .tooLong)
        }

        // Substitutions anywhere: confirm, before any tokenization.
        if trimmed.contains("$(") || trimmed.contains("`")
            || trimmed.contains("<(") || trimmed.contains(">(") {
            return .needsConfirmation(reason: .substitution)
        }

        // Tier 0: shell-free single command on the allowlist.
        if !containsShellOperator(trimmed),
           !hasShellExpansion(trimmed),
           let tokens = tokenize(trimmed),
           let binaryName = tokens.first,
           let path = resolveBinary(binaryName) {
            if hasWriteFlag(tokens) {
                return .needsConfirmation(reason: .modifiesFiles)
            }
            if isAllowlisted(binaryName: binaryName, resolvedPath: path, argv: tokens) {
                return .autoApproved(argv: tokens)
            }
        }

        // Tier 1: every segment of the compound matches a session prefix.
        if !sessionPrefixes.isEmpty,
           let segments = splitCompounds(trimmed),
           segments.allSatisfy({ segmentMatchesPrefix($0, prefixes: sessionPrefixes) }) {
            return .sessionApproved(command: trimmed)
        }

        // Tier 2: confirm, with the best-matching risk label.
        return .needsConfirmation(reason: riskReason(trimmed))
    }

    /// After wrappers are stripped: is this an allowlisted read-only
    /// binary? git additionally needs a read-only subcommand.
    static func isAllowlisted(binaryName: String, resolvedPath: String, argv: [String]) -> Bool {
        let resolved = (resolvedPath as NSString).lastPathComponent
        guard allowlist.contains(resolved) else { return false }
        if resolved == "git" {
            var index = 1
            // Skip global flags; -C and --git-dir take a value.
            while index < argv.count, argv[index].hasPrefix("-") {
                if argv[index] == "-C" || argv[index] == "--git-dir" {
                    index += 2
                } else {
                    index += 1
                }
            }
            guard index < argv.count else { return false }
            return gitReadOnlySubcommands.contains(argv[index])
        }
        return true
    }

    /// Unquoted occurrence of any of the given characters. `(` and `)` do
    /// not count here; they are handled with operators.
    static func hasUnquoted(_ chars: [Character], in command: String) -> Bool {
        var quote: Character? = nil
        for ch in command {
            if let open = quote {
                if ch == open { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                continue
            }
            if chars.contains(ch) { return true }
        }
        return false
    }

    /// Tier 2 risk label, ordered so the structural reason wins: a
    /// compound separator describes the command better than the presence
    /// of rm inside one of its segments.
    static func riskReason(_ command: String) -> CommandRisk {
        if hasUnquoted(["&", "|", ";", "\n"], in: command) {
            return .compound
        }
        if command.contains("$(") || command.contains("`")
            || command.contains("<(") || command.contains(">(") {
            return .substitution
        }
        if hasUnquoted([">", "<"], in: command) {
            return .shellSyntax
        }
        if hasShellExpansion(command) {
            return .shellSyntax
        }
        if tokenize(command) == nil {
            return .unparseable
        }
        if command.contains("rm ") || command.contains(" rm") || command.hasPrefix("rm") {
            return .modifiesFiles
        }
        return .unknownCommand
    }

    /// Tier 1 gate: does one compound segment match a prefix rule?
    /// Rules are exact commands or `prefix *` wildcards; the full
    /// shell-operator and substitution checks still apply to the segment.
    static func segmentMatchesPrefix(_ segment: String, prefixes: [String]) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsShellOperator(trimmed) { return false }

        guard let tokens = tokenize(trimmed), !needsShell(tokens) else { return false }
        let normalized = tokens.joined(separator: " ")

        for prefix in prefixes {
            let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPrefix.isEmpty else { continue }

            if normalized == normalizedPrefix { return true }

            if normalizedPrefix.hasSuffix("*") {
                let base = String(normalizedPrefix.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !base.isEmpty {
                    if normalized == base { return true }
                    if normalized.hasPrefix(base + " ") { return true }
                }
            }
        }
        return false
    }
}
