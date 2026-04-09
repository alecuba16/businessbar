import SwiftUI
import AppKit

@MainActor
final class OnboardingWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Welcome to BusinessBar"
        window.contentView = NSHostingView(rootView: OnboardingView())
        
        self.init(window: window)
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
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
                    onNext: finishOnboarding
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
