import SwiftUI
import AppKit

@MainActor
final class TutorialWindowController: NSWindowController, NSWindowDelegate {
    // Retains the presented controller so re-presenting always reuses it;
    // nilled on close so the SwiftUI view tree is released with the window.
    private static var current: TutorialWindowController?

    static func present() {
        if let current = current {
            current.show()
            return
        }
        let controller = TutorialWindowController()
        current = controller
        controller.show()
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.center()
        window.title = "BusinessBar Tutorial"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TutorialView(close: { [weak window] in window?.close() }))
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TutorialView: View {
    @State private var currentPage = 0
    var close: () -> Void = { NSApp.keyWindow?.close() }

    private var pages: [TutorialPage] { TutorialCatalog.pages }

    var body: some View {
        VStack(spacing: 0) {
            TutorialPageView(page: pages[currentPage])
                .id(currentPage)

            Divider()

            HStack {
                Button("Back") {
                    if currentPage > 0 { currentPage -= 1 }
                }
                .disabled(currentPage == 0)

                Spacer()

                Text("\(currentPage + 1) of \(pages.count)")
                    .foregroundColor(.secondary)

                Spacer()

                Button("Next") {
                    if currentPage < pages.count - 1 { currentPage += 1 }
                }
                .disabled(currentPage == pages.count - 1)

                Button("Close") {
                    close()
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TutorialPageView: View {
    let page: TutorialPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: page.systemImage)
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text(page.title)
                .font(.largeTitle)
                .bold()

            Text(page.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(40)
    }
}
