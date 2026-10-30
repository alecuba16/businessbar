import SwiftUI
import AppKit
import BusinessBarCore

@MainActor
final class OnboardingWindowController: NSWindowController {
    convenience init() {
        self.init(onboardingView: OnboardingView())
    }

    convenience init(onboardingView: OnboardingView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Welcome to BusinessBar"
        window.contentView = NSHostingView(rootView: onboardingView)
        
        self.init(window: window)
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    private let permissionStatus: () async -> PermissionsStep.PermissionStatus
    private let requestAccessibility: @MainActor () -> Void
    private let accessibilityRefreshDelay: () async -> Void

    init(
        permissionStatus: @escaping () async -> PermissionsStep.PermissionStatus = { await PermissionsStep.livePermissionStatus() },
        requestAccessibility: @escaping @MainActor () -> Void = { BadgeManager.requestAccessibilityPermission() },
        accessibilityRefreshDelay: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.permissionStatus = permissionStatus
        self.requestAccessibility = requestAccessibility
        self.accessibilityRefreshDelay = accessibilityRefreshDelay
    }

    @State private var currentStep = 0
    
    var body: some View {
        VStack {
            TabView(selection: $currentStep) {
                WelcomeStep {
                    currentStep = 1
                }
                    .tag(0)
                
                PermissionsStep(
                    onBack: { currentStep = 0 },
                    onNext: finishOnboarding,
                    permissionStatus: permissionStatus,
                    requestAccessibility: requestAccessibility,
                    accessibilityRefreshDelay: accessibilityRefreshDelay
                )
                    .tag(1)
            }
            .onAppear {
                // Default to first screen when opening onboarding.
                currentStep = 0
            }
            .tabViewStyle(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishOnboarding() {
        NSApp.keyWindow?.close()
    }
}
