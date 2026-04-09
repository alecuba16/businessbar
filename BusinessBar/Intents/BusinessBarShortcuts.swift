import AppIntents

struct BusinessBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: JoinNextMeetingIntent(),
            phrases: [
                "Join my next meeting in \(.applicationName)",
                "Join next meeting"
            ],
            shortTitle: "Join Next Meeting",
            systemImageName: "video.fill"
        )
        
        AppShortcut(
            intent: GetNextEventIntent(),
            phrases: [
                "Get my next event in \(.applicationName)",
                "What's my next meeting"
            ],
            shortTitle: "Get Next Event",
            systemImageName: "calendar"
        )
        
        AppShortcut(
            intent: ToggleNoSleepIntent(),
            phrases: [
                "Toggle NoSleep in \(.applicationName)",
                "Keep my Mac awake"
            ],
            shortTitle: "Toggle NoSleep",
            systemImageName: "cup.and.heat.waves"
        )
    }
}
