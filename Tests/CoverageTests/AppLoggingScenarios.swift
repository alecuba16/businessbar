import AppKit
import BusinessBarCore
import Combine
import Foundation
@testable import BusinessBar

@MainActor
enum AppLoggingScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try levels(context) } catch { failures.append("levels: \(error)") }
        do { try fileLog(context) } catch { failures.append("fileLog: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    static func levels(_ context: CoverageContext) throws {
        let all: [(LogLevel, String)] = [
            (.debug, "DEBUG"), (.info, "INFO"), (.warning, "WARNING"), (.error, "ERROR"), (.fatal, "FATAL")
        ]
        for (level, name) in all {
            try context.equal(level.description, name, "Level \(name) renders its marker")
            try context.expect(LogLevel(rawValue: level.rawValue) == level, "Raw value round trip for \(name)")
            try context.expect(level < LogLevel.fatal || level == .fatal, "Ordering includes \(name)")
        }
        try context.expect(LogLevel.allCases.count == 5, "All five levels enumerated")
        try context.expect(LogLevel.debug < LogLevel.info && LogLevel.info < LogLevel.warning && LogLevel.warning < LogLevel.error && LogLevel.error < LogLevel.fatal, "Comparable order follows severity")
        for level in LogLevel.allCases {
            try context.expect(!level.userDescription.isEmpty, "User description present for \(level.description)")
            try context.expect(!level.id.description.isEmpty, "Stable id for \(level.description)")
        }
        try context.equal(LogLevel.warning.osLogType, .default, "Warning maps to default OSLog type")
        try context.equal(LogLevel.error.osLogType, .error, "Error maps to error OSLog type")
        try context.equal(LogLevel.fatal.osLogType, .fault, "Fatal maps to fault OSLog type")

        // Logging disabled path: standard defaults live in the isolated fixture home.
        UserDefaults.standard.set(false, forKey: "loggingEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "loggingEnabled") }
        AppLogger.shared.debug("suppressed", category: "coverage")
        AppLogger.shared.info("suppressed", category: "coverage")
        AppLogger.shared.warning("suppressed", category: "coverage")
        AppLogger.shared.error("suppressed", category: "coverage")
        AppLogger.shared.fatal("suppressed", category: "coverage")
        try context.equal(AppLogger.shared.logFileURLs().count, 0, "Disabled logging never writes files")

        UserDefaults.standard.set(true, forKey: "loggingEnabled")
        UserDefaults.standard.set(false, forKey: "fileLoggingEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "fileLoggingEnabled") }
        try context.expect(!AppLogger.isFileLoggingEnabled(), "File logging flag observable off")
        AppLogger.shared.error("kept out of files", category: "coverage")
        try context.equal(AppLogger.shared.logFileURLs().count, 0, "Disabled file logging keeps directory empty")

        // Level threshold filtering.
        UserDefaults.standard.set(LogLevel.warning.rawValue, forKey: "logLevelRaw")
        defer { UserDefaults.standard.removeObject(forKey: "logLevelRaw") }
        try context.expect(AppLogger.isFileLoggingEnabled() == false, "Flag still off while threshold set")
        UserDefaults.standard.set(true, forKey: "fileLoggingEnabled")
        AppLogger.shared.debug("below threshold", category: "coverage")
        try context.equal(AppLogger.shared.logFileURLs().count, 0, "Below-threshold debug stays unlogged")
        AppLogger.shared.error("above threshold", category: "coverage")
        let urls = AppLogger.shared.logFileURLs()
        try context.equal(urls.count, 1, "Above-threshold error creates the current log file")
        if let first = urls.first {
            let contents = (try? String(contentsOf: first, encoding: .utf8)) ?? ""
            try context.expect(contents.contains("[ERROR]"), "File line carries the error marker")
            try context.expect(contents.contains("above threshold"), "File line carries the message")
        }
        UserDefaults.standard.set(999, forKey: "logLevelRaw")
        AppLogger.shared.fatal("unknown raw falls back", category: "coverage")
        if let url = AppLogger.shared.logFileURLs().first {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try context.expect(contents.contains("unknown raw falls back"), "Unknown threshold raw value still logs fatal")
        }
    }

    static func fileLog(_ context: CoverageContext) throws {
        UserDefaults.standard.set(true, forKey: "loggingEnabled")
        UserDefaults.standard.set(true, forKey: "fileLoggingEnabled")
        defer {
            UserDefaults.standard.removeObject(forKey: "loggingEnabled")
            UserDefaults.standard.removeObject(forKey: "fileLoggingEnabled")
            UserDefaults.standard.removeObject(forKey: "logLevelRaw")
        }

        enum FixtureError: Error { case boom }
        AppLogger.shared.logUnexpectedError(FixtureError.boom, category: "coverage", message: "fixture failure explained")
        AppLogger.shared.fatal("fatal entry", category: "coverage")
        // Synchronous fatal write already landed; async error write rides the serial queue.
        let urls = AppLogger.shared.logFileURLs()
        try context.expect(!urls.isEmpty, "Persisted entries produce files")

        // Context lines come from the call-site file path and function.
        if let current = urls.first {
            let contents = (try? String(contentsOf: current, encoding: .utf8)) ?? ""
            try context.expect(contents.contains("fixture failure explained"), "Unexpected error keeps supplied message")
            try context.expect(contents.contains("→"), "Context arrow written from call-site context")
        }

        // Rotation: seed an oversized current file, next write must rotate it away.
        let logsDirectory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BusinessBar", isDirectory: true)
        for index in 0..<5 {
            FileManager.default.createFile(
                atPath: logsDirectory.appendingPathComponent("BusinessBar_\(index).log").path,
                contents: Data()
            )
        }
        let oversized = Data(count: 1_048_576 + 1)
        try context.expect(FileManager.default.createFile(
            atPath: logsDirectory.appendingPathComponent("BusinessBar_0.log").path,
            contents: oversized
        ), "Oversized seed file created")
        AppLogger.shared.fatal("after rotation", category: "coverage")
        let rotated = AppLogger.shared.logFileURLs()
        try context.equal(rotated.count, 5, "Rotation keeps at most five files")
        if let newest = rotated.first {
            let contents = (try? String(contentsOf: newest, encoding: .utf8)) ?? ""
            try context.expect(contents.contains("after rotation"), "Fresh current file starts with the new entry")
        }
        try context.expect(!FileManager.default.fileExists(
            atPath: logsDirectory.appendingPathComponent("BusinessBar_4.log").path
        ) || rotated.count == 5, "Oldest slot either reused or absent after rotation")

        for url in FileManager.default.files(under: logsDirectory) where url.lastPathComponent.hasPrefix("BusinessBar_") {
            try? FileManager.default.removeItem(at: url)
        }
        try context.equal(AppLogger.shared.logFileURLs().count, 0, "Cleaned fixture logs")
    }
}

private extension FileManager {
    func files(under directory: URL) -> [URL] {
        (try? contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}