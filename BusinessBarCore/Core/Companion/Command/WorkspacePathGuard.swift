import Foundation

/// Workspace containment checks for the command tool. Every read_file and
/// list_files call re-checks that the requested path lands inside the
/// session's workspace root after symlink resolution.
public enum WorkspacePathGuard: Sendable {
    /// Resolves a filesystem path so every existing component is real:
    /// realpath(3) on the longest existing ancestor, then the missing tail
    /// re-appended verbatim. realpath(3) alone fails when the final
    /// component does not exist, which would leave `..` and symlink
    /// components unresolved and defeat the containment compare.
    static func resolvingComponents(_ path: String) -> String {
        var current = path
        var missingTail: [String] = []
        while true {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if realpath(current, &buffer) != nil {
                var resolved = String(cString: buffer)
                for component in missingTail.reversed() {
                    resolved += "/" + component
                }
                return resolved
            }
            let parent = (current as NSString).deletingLastPathComponent
            let last = (current as NSString).lastPathComponent
            if parent == current || last.isEmpty {
                return path
            }
            missingTail.append(last)
            current = parent
        }
    }

    /// True when `path` (absolute, or relative to `root`) resolves inside
    /// `root`. Both sides resolve every existing component, so symlinked
    /// subdirectories and the /var -> /private/var alias cannot escape,
    /// and the comparison is on full path components so
    /// /Users/me/root-evil does not match /Users/me/root.
    public static func isContained(
        _ path: String,
        root: String
    ) -> Bool {
        guard !root.isEmpty else { return false }

        let rootPath = resolvingComponents(root)
        guard !rootPath.isEmpty else { return false }

        // Absolute requests are taken as-is; relative ones resolve against
        // the root.
        let combined: String
        if path.hasPrefix("/") {
            combined = path
        } else {
            let clean = path.isEmpty ? "." : path
            combined = rootPath + "/" + clean
        }

        let target = resolvingComponents(combined)

        // Exact root match, or a child at a component boundary.
        if target == rootPath { return true }
        return target.hasPrefix(rootPath + "/")
    }

    /// Resolves `path` against `root` and returns the absolute filesystem
    /// path, or nil when the result escapes the workspace.
    public static func resolve(
        _ path: String,
        root: String
    ) -> String? {
        guard isContained(path, root: root) else { return nil }

        let rootPath = resolvingComponents(root)
        if path.hasPrefix("/") {
            return resolvingComponents(path)
        }
        let clean = path.isEmpty ? "." : path
        return resolvingComponents(rootPath + "/" + clean)
    }
}
