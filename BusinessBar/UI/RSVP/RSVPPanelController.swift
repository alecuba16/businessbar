import AppKit
import BusinessBarCore
import SwiftUI

/// Borderless panels refuse key status by default, leaving the y/m/n and
/// Escape shortcuts dead. Overriding canBecomeKey restores them without
/// activating the app.
fileprivate final class RSVPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - RSVPPanelController

/// Presents the pending invitations one by one in a small panel. Each card
/// shows the event with Yes / No / Maybe buttons; answering advances to the
/// next pending invite. The panel closes when the list is exhausted or the
/// user dismisses it. Reopened while running, it re-syncs to the current
/// pending list.
///
/// Window behavior mirrors the app's other auxiliary windows: borderless
/// non-activating panel at floating level so clicking the buttons never
/// yanks focus from the app the user is working in.
@MainActor
final class RSVPPanelController: NSObject, NSWindowDelegate {
    static let shared = RSVPPanelController(effects: .live)

    private var panel: NSPanel?
    /// Placeholder until present() swaps in the real pending list.
    private var store = RSVPPanelStore(events: [], respond: { _, _ in false })

    struct Effects {
        var makePanel: () -> NSPanel = {
            let p = RSVPPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 0),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            return p
        }
        var respond: @MainActor (CalendarEvent, CalendarEvent.RSVPStatus) async -> Bool
        var pendingEvents: @MainActor () -> [CalendarEvent]

        static var live: Effects {
            Effects(
                respond: { event, status in
                    guard let manager = AppDelegate.sharedMeetingManager() else { return false }
                    return await manager.respond(to: event, status: status)
                },
                pendingEvents: {
                    AppDelegate.sharedMeetingManager()?.pendingRSVPEvents ?? []
                }
            )
        }
    }

    private let effects: Effects

    /// Coverage access to the on-screen store: the panel drives the same
    /// object the buttons drive, so scenarios can assert on it.
    var storeForCoverage: RSVPPanelStore { store }

    /// Coverage access to the presented panel visibility.
    var panelForCoverage: NSPanel? { panel }

    init(effects: Effects) {
        self.effects = effects
        super.init()
    }

    // MARK: - Presentation

    func present() {
        let pending = effects.pendingEvents()
        guard !pending.isEmpty else { return }

        let effects = self.effects
        store = RSVPPanelStore(events: pending, respond: effects.respond)

        if panel == nil {
            let p = effects.makePanel()
            p.delegate = self
            panel = p
        }

        let view = RSVPPanelView(store: store) { [weak self] in
            self?.dismissPanel()
        }
        store.onFinish = { [weak self] in self?.dismissPanel() }
        // Height follows content: hosting view sized intrinsically.
        let hosting = NSHostingView(rootView: view)
        panel?.contentView = hosting
        let size = hosting.fittingSize
        panel?.setContentSize(NSSize(width: 360, height: size.height))

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            // Top-right corner: right inset keeps distance from the
            // rounded screen edge, top inset stays below the menu bar.
            let rightInset: CGFloat = 24
            let topInset: CGFloat = 16
            let x = visible.maxX - 360 - rightInset
            let y = visible.maxY - size.height - topInset
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Key panel without app activation: shortcuts (y/m/n, Escape)
        // work while focus stays where the user had it.
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismissPanel() {
        panel?.orderOut(nil)
    }
}

// MARK: - RSVPPanelStore

/// State for the invitation iteration: the pending events, the index of the
/// one on screen, and the in-flight answer.
@MainActor
final class RSVPPanelStore: ObservableObject {
    @Published private(set) var events: [CalendarEvent]
    @Published private(set) var index = 0
    @Published private(set) var isAnswering = false
    @Published private(set) var lastError: String?

    private let respond: @MainActor (CalendarEvent, CalendarEvent.RSVPStatus) async -> Bool
    /// Replaced by the panel controller once the view is on screen so the
    /// last answer closes the panel instead of leaving a dead card up.
    var onFinish: () -> Void = {}

    init(events: [CalendarEvent], respond: @escaping @MainActor (CalendarEvent, CalendarEvent.RSVPStatus) async -> Bool) {
        self.events = events
        self.respond = respond
    }

    var current: CalendarEvent? {
        guard index < events.count else { return nil }
        return events[index]
    }

    var progressText: String {
        "\(index + 1) of \(events.count)"
    }

    func answer(_ status: CalendarEvent.RSVPStatus) {
        guard !isAnswering, let event = current else { return }
        isAnswering = true
        lastError = nil
        Task { @MainActor in
            let ok = await self.respond(event, status)
            self.isAnswering = false
            if ok {
                self.advance()
            } else {
                self.lastError = "Could not send the answer. Try again or answer from Calendar."
            }
        }
    }

    private func advance() {
        if index + 1 < events.count {
            index += 1
        } else {
            onFinish()
        }
    }
}

// MARK: - RSVPPanelView

private struct RSVPPanelView: View {
    @ObservedObject var store: RSVPPanelStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let event = store.current {
                HStack {
                    Text("Invitation")
                        .font(.headline)
                    Spacer()
                    Text(store.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                    Text(Self.detailLine(event))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let organizer = event.organizer, !organizer.isEmpty {
                        Text("Invited by \(organizer)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    Button("Yes") { store.answer(.accepted) }
                        .keyboardShortcut("y")
                        .disabled(store.isAnswering)
                    Button("Maybe") { store.answer(.tentative) }
                        .keyboardShortcut("m")
                        .disabled(store.isAnswering)
                    Button("No") { store.answer(.declined) }
                        .keyboardShortcut("n")
                        .disabled(store.isAnswering)
                }
                if store.isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private static func detailLine(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var line = formatter.string(from: event.startDate)
        if let location = event.location, !location.isEmpty {
            line += " · \(location)"
        }
        return line
    }
}