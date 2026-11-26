import Foundation

struct TutorialPage: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let body: String
}

enum TutorialCatalog {
    static let pages: [TutorialPage] = [
        TutorialPage(
            id: "meetings",
            title: "Meetings",
            systemImage: "calendar.badge.clock",
            body: """
            The menu bar shows a countdown to your next meeting. \
            Clicking it joins the meeting, with one-click join links for 50+ meeting services.

            Calendars preferences choose EventKit or Google, which calendars to show, \
            the notification lead time, and end-of-event alerts.
            """
        ),
        TutorialPage(
            id: "badges",
            title: "Notification Badges",
            systemImage: "app.badge",
            body: """
            Dock badges of the apps you pick appear as icons in the menu bar. \
            Clicking an icon focuses that app.

            Badges preferences hold the app picker, the icon size, \
            and the grayscale look when notifications are quiet. \
            This feature needs Accessibility permission.
            """
        ),
        TutorialPage(
            id: "nosleep",
            title: "NoSleep",
            systemImage: "cup.and.heat.waves",
            body: """
            Keep the Mac awake for a fixed duration or indefinitely. \
            Choose system-only or system and display modes, plus optional activity simulation.

            Start it from the menu bar menu or automatically at launch.
            """
        ),
        TutorialPage(
            id: "companion",
            title: "LLM Companion",
            systemImage: "bubble.left.and.text.bubble.right",
            body: """
            A floating chat panel that stays over fullscreen apps. \
            It rewrites selected text through per-template shortcuts.

            Connect OpenAI-compatible endpoints, local MLX models, or ACP agents. \
            Chat history is saved on disk.
            """
        ),
        TutorialPage(
            id: "companion-tools",
            title: "Companion Tools",
            systemImage: "wrench.and.screwdriver",
            body: """
            The model can call chat tools: web search, GitHub code search, \
            and a command runner scoped to a working directory with permission prompts.

            Turn each tool on or off in Companion preferences.
            """
        ),
        TutorialPage(
            id: "shortcuts",
            title: "Shortcuts",
            systemImage: "keyboard",
            body: """
            Global shortcuts cover join meeting, open menu, \
            and per-template rewrites.

            Record them in the General and Companion preferences.
            """
        ),
        TutorialPage(
            id: "preferences",
            title: "Preferences",
            systemImage: "gearshape",
            body: """
            Every feature has its own tab in Preferences, \
            and the feature toggles live in those tabs.

            Appearance controls status bar text and badge icon sizes. \
            Logging and reset options live in General.
            """
        )
    ]
}
