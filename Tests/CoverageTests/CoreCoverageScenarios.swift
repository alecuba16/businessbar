import Foundation

@MainActor
enum CoreCoverageScenarios {
    static func run(_ context: CoverageContext) async throws {
        let suites: [(String, @MainActor (CoverageContext) async throws -> Void)] = [
            ("command/persistence", CoreCommandPersistenceScenarios.run),
            ("network/ACP", CoreNetworkScenarios.run),
            ("MLX", CoreMLXScenarios.run),
            ("badges/NoSleep", CoreSystemScenarios.run),
            ("meeting/utilities", CoreMeetingUtilitiesScenarios.run)
        ]
        var failures: [String] = []
        for (name, scenario) in suites {
            let before = context.checks
            let started = Date()
            print("RUN: Core \(name)")
            do {
                try await scenario(context)
                print("PASS: Core \(name), \(context.checks - before) checks in \(Int(Date().timeIntervalSince(started)))s")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: Core \(name): \(error)")
            }
        }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
