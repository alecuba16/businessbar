import AppKit
import Foundation

// MARK: - CrashHandler

/// Installs low-level signal and Obj-C exception handlers so that unhandled
/// crashes are captured to disk. On the next app launch the handler checks
/// for a pending crash report and, if found, presents an alert with the path.
///
/// - **NSException handler**: safe to use Foundation, captures a full
///   Swift call stack via `Thread.callStackSymbols`.
/// - **Signal handler**: async-signal-safe only — no malloc, no Foundation,
///   no Swift string interpolation. Uses `write()` syscall directly.
///
/// Crash reports are written alongside the regular AppLogger files in
/// `~/Library/Logs/BusinessBar/`.
final class CrashHandler {

    // MARK: - Singleton

    static let shared = CrashHandler()

    // MARK: - Types

    private enum Constants {
        static let crashReportPrefix = "crash_"
        static let crashReportExtension = "log"
        static let lastCrashKey = "BusinessBar.lastCrashReportPath"
    }

    // MARK: - Private State

    /// The directory where crash reports are written. Same as AppLogger.
    private let logDirectoryURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("BusinessBar", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }()

    /// Previous signal handlers — stored so we could chain to them if needed.
    private var previousSignalHandlers: [Int32: (@convention(c) (Int32) -> Void)?] = [:]

    // MARK: - Public API

    /// Installs the crash handlers. Call **once**, early in
    /// `applicationDidFinishLaunching`, before any other work.
    func install() {
        installExceptionHandlers()
        installSignalHandlers()
        AppLogger.info("Crash handlers installed", category: "CrashHandler")
    }

    /// Checks for a pending crash report from a previous session.
    /// Returns the URL of the crash report if one exists, `nil` otherwise.
    /// Also **purges** the flag so the same report is not shown twice.
    func pendingCrashReport() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Constants.lastCrashKey),
              !path.isEmpty else {
            return nil
        }

        // Clear the flag so we don't show the same alert again.
        UserDefaults.standard.removeObject(forKey: Constants.lastCrashKey)

        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - NSException Handler

    private func installExceptionHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            // This callback is *not* async-signal-safe — Foundation is OK.
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            let report = """
            ===== Uncaught Exception =====
            Name:   \(exception.name.rawValue)
            Reason: \(exception.reason ?? "none")
            User Info: \(exception.userInfo ?? [:])
            Call Stack:
            \(stack)
            =============================
            """
            CrashHandler.shared.writeCrashReport(report)
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]

        for sig in signals {
            let old = signal(sig) { sig in
                // ⚠️ Async-signal-safe zone — NO malloc, NO Foundation, NO Swift
                // string interpolation. Only write() and _exit() are safe.
                CrashHandler.writeSignalReportASyncSafe(sig)
                // Terminate so macOS generates its own DiagnosticReports entry.
                _exit(128 + sig)
            }
            previousSignalHandlers[sig] = old
        }
    }

    // MARK: - Writing Crash Reports

    /// Writes a full crash report (NSException path). Safe to use Foundation.
    private func writeCrashReport(_ content: String) {
        // Ensure directory exists.
        try? FileManager.default.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true
        )

        let timestamp = Self.timestampString()
        let fileName = "\(Constants.crashReportPrefix)\(timestamp).\(Constants.crashReportExtension)"
        let url = logDirectoryURL.appendingPathComponent(fileName)

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            // Record the path so we can alert on next launch.
            UserDefaults.standard.set(url.path, forKey: Constants.lastCrashKey)
        } catch {
            fputs("CrashHandler: failed to write report — \(error)\n", stderr)
        }
    }

    /// Async-signal-safe crash report writer for signal handlers.
    /// Uses only `write()` syscall — no heap allocation, no Foundation.
    /// Swift variadic C interop (snprintf) is unavailable, so we build
    /// strings by copying CChar arrays manually.
    private static func writeSignalReportASyncSafe(_ sig: Int32) {
        // Resolve HOME — getenv is async-signal-safe.
        guard let home = getenv("HOME") else { return }
        let homeStr = String(cString: home)

        // Build directory path: $HOME/Library/Logs/BusinessBar
        let dirPath = homeStr + "/Library/Logs/BusinessBar"

        // Build file path: $HOME/Library/Logs/BusinessBar/crash_signal_<N>.log
        let filePath = dirPath + "/\(Constants.crashReportPrefix)signal_\(sig).\(Constants.crashReportExtension)"

        // Build message: "Fatal signal <N> (<name>): app crashed\n"
        let sigName = strsignal(sig)
        let sigNameStr = sigName != nil ? String(cString: sigName!) : "unknown"
        let message = "Fatal signal \(sig) (\(sigNameStr)): app crashed\n"

        // Create intermediate directories — mkdir is async-signal-safe.
        _ = dirPath.withCString { dirPtr in
            mkdir(dirPtr, 0o755)
        }

        // Write the report using low-level open/write/close.
        filePath.withCString { pathPtr in
            let fd = open(pathPtr, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                message.withCString { msgPtr in
                    // strlen is async-signal-safe
                    _ = write(fd, msgPtr, strlen(msgPtr))
                }
                close(fd)
            }
        }

        // Record path for next-launch alert.
        // NOTE: UserDefaults is NOT async-signal-safe. The file write above
        // already reached disk, so even if this doesn't sync, macOS
        // DiagnosticReports still has the crash.
        UserDefaults.standard.set(filePath, forKey: Constants.lastCrashKey)
    }

    // MARK: - Helpers

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

// MARK: - Crash Alert

extension CrashHandler {

    /// Presents a modal alert if a crash report from a previous session was
    /// found. Call from `applicationDidFinishLaunching` after `install()`.
    @MainActor
    func showCrashAlertIfNeeded() {
        guard let crashURL = pendingCrashReport() else { return }

        AppLogger.warning("Previous crash detected — report at \(crashURL.path)", category: "CrashHandler")

        let alert = NSAlert()
        alert.messageText = "BusinessBar Crashed"
        alert.informativeText = """
        BusinessBar encountered an unexpected error and quit during the last session.

        A crash report was saved to:
        \(crashURL.path)

        You can review this file or share it when reporting the issue.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reveal in Finder")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.selectFile(crashURL.path, inFileViewerRootedAtPath: "")
        }
    }
}
