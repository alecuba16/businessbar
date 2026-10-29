import Foundation

/// Static tool schemas for the companion's command-execution tools,
/// following the SearchToolCatalog pattern: plain dictionaries handed to
/// the OpenAI-compat client, no advertisement when the feature is off.
public enum CommandToolCatalog {
    /// All command-tool schemas in one array, or an empty array when the
    /// feature is disabled. The caller decides enablement.
    public static func toolSchemas() -> [[String: Any]] {
        [
            runCommandToolSchema(),
            readFileToolSchema(),
            listFilesToolSchema(),
            listBackgroundProcessesToolSchema(),
            readBackgroundOutputToolSchema(),
            stopBackgroundProcessToolSchema(),
        ]
    }

    public static func runCommandToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "run_command",
                "description": "Run a shell command in the session's workspace folder. Read-only commands like ls, cat, grep run without asking. Commands that modify files or have unknown effects require the user's confirmation first. The user may also have the runner set to Allow (no confirmation) or Deny (every call is refused); when a call is denied, ask the user to change the mode in the chat header instead of retrying. Use background: true for long-running commands like dev servers; you will get a handle and can read its output later.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to run."
                        ],
                        "background": [
                            "type": "boolean",
                            "description": "True to return immediately with a handle while the command keeps running. Default false."
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ]
    }

    public static func readFileToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read a text file from the workspace folder. Never needs confirmation.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path, relative to the workspace folder or absolute."
                        ],
                        "offset": [
                            "type": "integer",
                            "description": "Line number to start reading from, 1-based. Default 1."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of lines to return. Default 500."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ]
    }

    public static func listFilesToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "list_files",
                "description": "List files and folders in the workspace folder or a subfolder. Never needs confirmation.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Folder path, relative to the workspace folder or absolute. Default the workspace root."
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "True to list recursively. Default false."
                        ]
                    ]
                ]
            ]
        ]
    }

    public static func listBackgroundProcessesToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "list_background_processes",
                "description": "List background commands started with run_command(background: true), with their status and handle.",
                "parameters": [
                    "type": "object",
                    "properties": [:]
                ]
            ]
        ]
    }

    public static func readBackgroundOutputToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "read_background_output",
                "description": "Read the recent output of a background command, given its handle.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "handle": [
                            "type": "string",
                            "description": "The handle returned by run_command."
                        ],
                        "lines": [
                            "type": "integer",
                            "description": "Number of recent lines to read. Default 50."
                        ]
                    ],
                    "required": ["handle"]
                ]
            ]
        ]
    }

    public static func stopBackgroundProcessToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "stop_background_process",
                "description": "Stop a background command by handle.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "handle": [
                            "type": "string",
                            "description": "The handle returned by run_command."
                        ]
                    ],
                    "required": ["handle"]
                ]
            ]
        ]
    }

    // MARK: - Argument decoding helpers

    /// Pulls `command` and optional `background` from a run_command
    /// arguments payload.
    public static func decodeRunCommandArguments(_ json: [String: Any]) -> (command: String, background: Bool)? {
        guard let command = json["command"] as? String, !command.isEmpty else { return nil }
        let background = json["background"] as? Bool ?? false
        return (command, background)
    }

    /// Pulls `path`, 1-based `offset`, and `limit` from a read_file
    /// arguments payload, with defaults.
    public static func decodeReadFileArguments(_ json: [String: Any]) -> (path: String, offset: Int, limit: Int) {
        let path = json["path"] as? String ?? ""
        let offset = max(1, json["offset"] as? Int ?? 1)
        let limit = min(max(1, json["limit"] as? Int ?? 500), 2_000)
        return (path, offset, limit)
    }

    /// Pulls `path` and `recursive` from a list_files arguments payload.
    public static func decodeListFilesArguments(_ json: [String: Any]) -> (path: String, recursive: Bool) {
        let path = json["path"] as? String ?? ""
        let recursive = json["recursive"] as? Bool ?? false
        return (path, recursive)
    }

    /// Pulls `handle` and `lines` from a read_background_output payload.
    public static func decodeReadBackgroundArguments(_ json: [String: Any]) -> (handle: String, lines: Int) {
        let handle = json["handle"] as? String ?? ""
        let lines = min(max(1, json["lines"] as? Int ?? 50), 500)
        return (handle, lines)
    }

    /// Pulls `handle` from a stop_background_process payload.
    public static func decodeStopArguments(_ json: [String: Any]) -> String? {
        guard let handle = json["handle"] as? String, !handle.isEmpty else { return nil }
        return handle
    }
}
