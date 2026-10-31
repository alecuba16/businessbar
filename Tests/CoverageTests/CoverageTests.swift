import Foundation
import XCTest

final class WholeApplicationBehaviorTests: XCTestCase {
    @MainActor
    func testSharedProductionScenarios() async throws {
        guard let home = ProcessInfo.processInfo.environment["BUSINESSBAR_COVERAGE_HOME"] else {
            XCTFail("Run through scripts/test-coverage.sh to isolate application storage")
            return
        }
        guard let record = ProcessInfo.processInfo.environment["BUSINESSBAR_XCTEST_RUN_RECORD"],
              let profile = ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] else {
            XCTFail("Coverage test process provenance was not configured")
            return
        }
        let metadata: [String: Any] = [
            "schema": 1,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "profile_pattern": profile,
            "home": home
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: record), options: .atomic)
        let root = URL(fileURLWithPath: home).appendingPathComponent("scenarios-" + UUID().uuidString)
        let context = try CoverageContext(root: root)
        defer { context.cleanup() }
        try await CoverageSuite.run(context)
        XCTAssertGreaterThan(context.checks, 0)
    }
}
