import Foundation

@MainActor
enum CoverageSuite {
    static func run(_ context: CoverageContext) async throws {
        guard let home = ProcessInfo.processInfo.environment["BUSINESSBAR_COVERAGE_HOME"] else {
            throw CoverageContext.Failure(description: "The coverage runner must provide an isolated application home")
        }
        let expectedHome = URL(fileURLWithPath: home).standardizedFileURL.path
        try context.equal(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path, expectedHome, "Application home is isolated")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        try context.expect(support?.standardizedFileURL.path.hasPrefix(expectedHome + "/") == true, "Application Support must remain inside the fixture home")
        try context.expect(Bundle.main.bundleIdentifier != "com.businessbar.app", "Tests must not use the live app preferences domain")
        let selected = ProcessInfo.processInfo.environment["BUSINESSBAR_COVERAGE_SUITE"] ?? "all"
        try context.expect(["all", "core", "app"].contains(selected), "Unknown coverage scenario selection: \(selected)")
        var failures: [String] = []
        if selected == "all" || selected == "core" {
            do {
                try await CoreCoverageScenarios.run(context)
                print("PASS: core behavior scenarios")
            } catch {
                failures.append("Core: \(error)")
            }
        }
        if selected == "all" || selected == "app" {
            do {
                try await AppCoverageScenarios.run(context)
                print("PASS: app behavior scenarios")
            } catch {
                failures.append("App: \(error)")
            }
        }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
