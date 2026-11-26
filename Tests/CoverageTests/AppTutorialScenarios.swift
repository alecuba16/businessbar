import AppKit
import BusinessBarCore
import Foundation
import SwiftUI
@testable import BusinessBar

@MainActor
enum AppTutorialScenarios {
    static func run(_ context: CoverageContext) async throws {
        print("TUT: catalog")
        try catalog(context)
        print("TUT: view")
        try await view(context)
        print("TUT: window controller")
        try windowController(context)
        print("TUT: general tab seam")
        try await generalTabSeam(context)
    }

    private static func catalog(_ context: CoverageContext) throws {
        let pages = TutorialCatalog.pages
        try context.equal(pages.count, 7, "Tutorial has seven pages")
        try context.equal(pages.map(\.id), ["meetings", "badges", "nosleep", "companion", "companion-tools", "shortcuts", "preferences"], "Page order and ids")
        try context.equal(Set(pages.map(\.id)).count, pages.count, "Page ids are unique")
        for page in pages {
            try context.expect(!page.title.isEmpty, "Title present: \(page.id)")
            try context.expect(!page.systemImage.isEmpty, "Symbol present: \(page.id)")
            try context.expect(!page.body.isEmpty, "Body present: \(page.id)")
        }
        try context.expect(pages.contains { $0.id == "meetings" && $0.systemImage == "calendar.badge.clock" }, "Meetings page keeps its symbol")
    }

    private static func view(_ context: CoverageContext) async throws {
        let hosted = Coverage2Hosted(TutorialView(), size: NSSize(width: 640, height: 520))
        defer { hosted.close() }
        await coverage2Settle()
        try context.expect(hosted.text.contains("Meetings"), "First page renders the Meetings title")
        try context.expect(hosted.text.contains("1 of 7"), "Indicator starts at page one")
        try context.expect(hosted.control("Back")?.isAccessibilityEnabled() == false, "Back disabled on the first page")

        // Walk forward: each press drives currentPage through the same
        // binding a user click uses, so every page body renders once.
        for page in TutorialCatalog.pages.dropFirst() {
            try hosted.press("Next", context)
            await coverage2Settle()
            try context.expect(hosted.text.contains(page.title), "Page renders after Next: \(page.id)")
        }
        try context.expect(hosted.text.contains("7 of 7"), "Indicator reaches the last page")
        try context.expect(hosted.control("Next")?.isAccessibilityEnabled() == false, "Next disabled on the last page")

        try hosted.press("Back", context)
        await coverage2Settle()
        try context.expect(hosted.text.contains("6 of 7"), "Back moves to the previous page")
        try context.expect(hosted.control("Back")?.isAccessibilityEnabled() == true, "Back enabled away from the first page")
    }

    private static func windowController(_ context: CoverageContext) throws {
        let controller = TutorialWindowController()
        try context.equal(controller.window?.title, "BusinessBar Tutorial", "Window title")
        try context.expect(controller.window?.contentView is NSHostingView<TutorialView>, "Content hosts the tutorial view")
        try context.expect(controller.window?.isReleasedWhenClosed == false, "Window survives Close for re-presenting")
        try context.expect(controller.window?.delegate === controller, "Controller is the window delegate so close releases it")
    }

    private static func generalTabSeam(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("tutorial-tab")
        let updater = UpdaterViewModel(backend: TutorialUpdaterBoundary())
        let auth = GoogleAuth(dependencies: .init(loadCredential: { throw CoverageContext.Failure(description: "fixture") }, saveCredential: { _ in }, deleteCredential: {}, configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") }, request: { _ in throw CoverageContext.Failure(description: "fixture") }, openURL: { _ in false }))
        var shows = 0
        let tab = Coverage2Hosted(
            GeneralTab(googleAuth: auth, showTutorial: { shows += 1 })
                .environmentObject(updater)
                .defaultAppStorage(defaults),
            size: NSSize(width: 800, height: 1200)
        )
        defer { tab.close() }
        await coverage2Settle()
        try context.expect(tab.text.contains("Take the Tutorial"), "General tab offers the tutorial button")
        try tab.press("Take the Tutorial", context)
        await coverage2Settle()
        try context.equal(shows, 1, "Tutorial press reaches the injected closure once")
    }
}

@MainActor
private final class TutorialUpdaterBoundary: UpdaterBackend {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = false
    func start() throws { canCheckForUpdates = true }
    func checkForUpdates() {}
}
