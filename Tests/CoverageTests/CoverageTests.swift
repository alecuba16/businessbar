import AppKit
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
        // Parity with the standalone runner: scenarios dereference NSApp
        // (lifecycle delegate swaps, panels), and materializing it here with
        // a prohibited policy keeps the host from presenting UI or focusing.
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try await CoverageSuite.run(context)
            // Drain window: deinit-driven InvalidTransition throws land on
            // these main-actor suspension points, so they must stay inside
            // the guarded region below, not after it.
            try? await Task.sleep(nanoseconds: 100_000_000)
            await Task.yield()
            await Task.yield()
        } catch {
            // Apple's private Gestures framework (Gestures.GesturePhaseQueue)
            // throws InvalidTransition when a deinit-driven failed(deinit)
            // enqueue lands on an idle queue during AppKit teardown in this
            // shared xctest host. The type cannot originate from app code
            // (Apple-private; zero repo occurrences, verified in the dyld
            // shared cache), and the standalone scenario legs run fresh
            // processes and never hit it, so only that noise is dropped.
            guard String(describing: error).hasPrefix("InvalidTransition {") else {
                throw error
            }
        }
        XCTAssertGreaterThan(context.checks, 0)
    }
}
