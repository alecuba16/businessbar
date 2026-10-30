import Foundation

@MainActor
final class CoverageContext {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var checks = 0
    let root: URL
    private var suites: [String] = []

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        checks += 1
        guard condition() else {
            throw Failure(description: "\(file):\(line): \(message)")
        }
    }

    func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try expect(actual == expected, "\(message): got \(actual), expected \(expected)", file: file, line: line)
    }

    func expectThrows(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch {
            checks += 1
            return
        }
        try expect(false, message, file: file, line: line)
    }

    func expectThrowsAsync(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            checks += 1
            return
        }
        try expect(false, message, file: file, line: line)
    }

    func temporaryDirectory(_ label: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: label).lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func defaults(_ label: String) throws -> UserDefaults {
        let name = "com.businessbar.coverage.\(UUID().uuidString).\(label)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw Failure(description: "Cannot create isolated defaults suite \(name)")
        }
        suites.append(name)
        return defaults
    }

    func cleanup() {
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
    }
}
