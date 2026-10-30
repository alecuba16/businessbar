import AppKit
import Foundation
import CryptoKit

#if !BUSINESSBAR_COVERAGE_NATIVE
@testable import BusinessBar
@testable import BusinessBarCore
#endif

enum CoverageRuntimeIsolation {
    static func verify() {
        do {
            try check()
        } catch {
            fputs("FAIL: coverage runtime isolation: \(error)\n", stderr)
            exit(1)
        }
    }

    static func snapshotSources(verify: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let repository = environment["BUSINESSBAR_COVERAGE_REPO_ROOT"],
              let snapshot = environment["BUSINESSBAR_COVERAGE_SOURCE_SNAPSHOT"],
              let objectsPath = environment["BUSINESSBAR_COVERAGE_ALL_OBJECTS"] else {
            throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "source integrity environment is missing"])
        }
        let manager = FileManager.default
        let objects = try String(contentsOfFile: objectsPath, encoding: .utf8).split(separator: "\n").map(String.init)
        var hashes: [String: String] = [:]
        for directory in ["BusinessBar", "BusinessBarCore"] {
            let root = URL(fileURLWithPath: repository).appendingPathComponent(directory)
            guard let files = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
                throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot enumerate \(directory)"])
            }
            for case let source as URL in files where source.pathExtension == "swift" {
                let values = try source.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relative = String(source.path.dropFirst(repository.count + 1))
                let digest = SHA256.hash(data: try Data(contentsOf: source))
                let afterRead = try manager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
                guard values.contentModificationDate == afterRead else {
                    throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "source changed while fingerprinting: \(relative)"])
                }
                hashes[relative] = digest.map { String(format: "%02x", $0) }.joined()
                if !verify && environment["BUSINESSBAR_COVERAGE_BUILT"] == "yes" {
                    let basename = source.deletingPathExtension().lastPathComponent
                    let aggregate = objects.filter { URL(fileURLWithPath: $0).lastPathComponent == "BusinessBarCore.o" }
                    let matches = directory == "BusinessBarCore" && aggregate.count == 1 ? aggregate : objects.filter { path in
                        let name = URL(fileURLWithPath: path).lastPathComponent
                        let belongsToCore = path.contains("/BusinessBarCore.build/") || path.contains("/BusinessBarCore-t.build/")
                        return (name == basename + ".o" || name == basename + ".swift.o") && (directory == "BusinessBarCore" ? belongsToCore : !belongsToCore)
                    }
                    guard matches.count == 1,
                          let sourceDate = values.contentModificationDate,
                          let objectDate = try URL(fileURLWithPath: matches[0]).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          sourceDate <= objectDate else {
                        throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "source is newer than its unique linked object, or object is missing: \(relative)"])
                    }
                }
            }
        }
        guard !hashes.isEmpty else {
            throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "production source snapshot is empty"])
        }
        let destination = URL(fileURLWithPath: snapshot)
        if verify {
            let before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: destination))
            guard before == hashes else {
                let changed = Set(before.keys).union(hashes.keys).filter { before[$0] != hashes[$0] }.sorted()
                throw NSError(domain: "CoverageRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "production Swift sources changed during the coverage run: \(changed.joined(separator: ", "))"])
            }
            print("PASS: \(hashes.count) production source hashes unchanged")
        } else {
            try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys]).write(to: destination, options: .atomic)
            print("PASS: captured \(hashes.count) production source SHA256 hashes")
        }
    }

    private static func check() throws {
        struct IsolationFailure: Error, CustomStringConvertible {
            let description: String
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw IsolationFailure(description: message) }
        }
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        func isInside(_ path: String, _ root: String) -> Bool {
            let path = normalized(path)
            let root = normalized(root)
            return path == root || path.hasPrefix(root + "/")
        }

        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["BUSINESSBAR_COVERAGE_HOME"],
              let temporary = environment["BUSINESSBAR_COVERAGE_TMP"],
              let identifier = environment["BUSINESSBAR_COVERAGE_BUNDLE_ID"] else {
            throw IsolationFailure(description: "run this binary through run-coverage-scenarios.sh")
        }
        try require(environment["HOME"].map(normalized) == normalized(home), "HOME is not isolated")
        try require(environment["CFFIXED_USER_HOME"].map(normalized) == normalized(home), "CFFIXED_USER_HOME is not isolated")
        try require(normalized(NSHomeDirectory()) == normalized(home), "NSHomeDirectory escaped the isolated home")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        try require(!support.isEmpty && support.allSatisfy { isInside($0.path, home) }, "Application Support escaped the isolated home")
        try require(environment["TMPDIR"].map(normalized) == normalized(temporary), "TMPDIR is not scoped to this run")
        if !isInside(FileManager.default.temporaryDirectory.path, temporary) {
            print("NOTE: Foundation temporaryDirectory remains system-managed; fixtures use the explicit coverage root")
        }
        try require(identifier.hasPrefix("com.businessbar.coverage."), "unexpected test preferences identifier")
        try require(Bundle.main.bundleIdentifier == identifier, "embedded bundle identifier does not match the isolated defaults domain")
        try require(UserDefaults.standard.persistentDomain(forName: identifier) == nil, "test preferences domain was already populated")
        print("PASS: isolation home=\(NSHomeDirectory()) defaults=\(identifier)")
    }
}

#if !BUSINESSBAR_COVERAGE_NATIVE
@main
struct CoverageRunner {
    @MainActor
    static func main() async {
        CoverageRuntimeIsolation.verify()
        do {
            if CommandLine.arguments.contains("--write-source-snapshot") {
                try CoverageRuntimeIsolation.snapshotSources(verify: false)
            }
            if CommandLine.arguments.contains("--verify-source-snapshot") {
                try CoverageRuntimeIsolation.snapshotSources(verify: true)
            }
        } catch {
            fputs("FAIL: source integrity: \(error)\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.contains("--isolation-only") {
            print("PASS: coverage startup isolation")
            return
        }
        #if !BUSINESSBAR_COVERAGE_ISOLATION
        guard let directory = ProcessInfo.processInfo.environment["BUSINESSBAR_COVERAGE_FIXTURES"] else {
            fputs("FAIL: missing isolated coverage fixture directory\n", stderr)
            exit(1)
        }
        do {
            let context = try CoverageContext(root: URL(fileURLWithPath: directory, isDirectory: true))
            defer { context.cleanup() }
            NSApplication.shared.setActivationPolicy(.prohibited)
            try await CoverageSuite.run(context)
            guard context.checks > 0 else {
                throw CoverageContext.Failure(description: "coverage suite executed no checks")
            }
            print("PASS: \(context.checks) coverage scenario checks")
        } catch {
            fputs("FAIL: coverage scenarios: \(error)\n", stderr)
            exit(1)
        }
        #endif
    }
}
#endif
