import AppKit
import BusinessBarCore
import Foundation
import SwiftUI
@testable import BusinessBar

@MainActor
enum AppCompanionViewScenarios {
    static func run(_ context: CoverageContext) async throws {
        let disk = ChatSessionStore(directoryURL: try context.temporaryDirectory("panel-history"))
        let store = ChatStore(sessionStore: disk)
        let commands = CommandToolController(presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))
        var presented: [NSPanel] = []
        var activations = 0
        var shutdowns = 0
        let controller = CompanionPanelController(chatStore: store, commandTools: commands, effects: .init(show: { presented.append($0) }, activate: { activations += 1 }, shutdownAgent: { shutdowns += 1 }))
        try context.expect(!controller.isPanelVisible, "Panel starts closed")
        controller.open(clientProvider: { nil })
        guard let panel = presented.first else { throw CoverageContext.Failure(description: "Missing owned panel") }
        defer { panel.close() }
        try context.expect(!panel.isVisible, "Injected presentation does not show or focus user windows")
        try context.equal(panel.contentRect(forFrameRect: panel.frame).size, NSSize(width: 420, height: 560), "Chat default content geometry")
        try context.expect(panel.canBecomeKey && !panel.canBecomeMain, "Panel keyboard semantics")
        try context.expect(panel.styleMask.contains(.nonactivatingPanel), "Chat panel remains nonactivating")
        try context.equal(panel.level, .floating, "Chat panel floats")
        try context.expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Panel supports fullscreen spaces")
        try context.expect(panel.contentView is NSHostingView<ChatView>, "Panel hosts real chat view")
        controller.open(clientProvider: { nil })
        try context.equal(presented.count, 2, "Reopen reuses owned panel")
        try context.expect(presented[0] === presented[1], "Panel instance stable across reopen")
        try context.equal(activations, 2, "Presentation activation callback routed, not executed live")
        store.startNewSession()
        try context.expect(commands.workspaceRoot == nil, "Chat session reset reaches command lifecycle")
        controller.close()
        try context.equal(shutdowns, 1, "Panel close requests agent release")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: panel))
        try context.expect(commands.approvalRequest == nil, "Panel closing leaves no approval")

        let empty = ChatView(store: store, commandTools: commands, clientProvider: { nil })
        try await render(empty, size: NSSize(width: 420, height: 560), context: context, label: "empty chat", expected: ["Ask anything", "No model configured yet."])
        store.messages = [ChatMessage(role: .user, content: "Fixture prompt"), ChatMessage(role: .assistant, content: "Fixture answer", thinking: "Reasoning fixture")]
        store.errorMessage = "Controlled failure"
        commands.backgroundProcesses = [.init(id: UUID(), command: "fixture", running: true, exitCode: nil, endedReason: nil), .init(id: UUID(), command: "finished fixture", running: false, exitCode: 3, endedReason: "fixture exit")]
        commands.approvalRequest = CommandApprovalRequest(command: "fixture approval", reason: .unknownCommand, category: .unknown, targets: ["fixture.txt"], workspaceRoot: context.root.path, completion: { _ in })
        try await render(ChatView(store: store, commandTools: commands, clientProvider: { nil }), size: NSSize(width: 420, height: 700), context: context, label: "error approval and processes", expected: ["Controlled failure", "Deny"])
        commands.approvalRequest = nil
        store.isStreaming = true
        store.streamingText = "Streaming fixture"
        store.streamingThinking = "Streaming reasoning"
        store.activityLabel = "Writing"
        try await render(ChatView(store: store, commandTools: commands, clientProvider: { nil }), size: NSSize(width: 620, height: 700), context: context, label: "streaming chat")
        store.isStreaming = false
        let roles: [ChatMessage.Role] = [.user, .assistant, .system]
        for role in roles {
            // The system bubble hugs its text width: production renders it
            // without the user-role spacer or the assistant fixedSize wrapper,
            // and NSHostingView follows that intrinsic width after layout.
            let widthFollowsContent = role == .system
            try await render(MessageBubble(message: ChatMessage(role: role, content: "plain \(role.rawValue) fixture"), onEditPrompt: {}), size: NSSize(width: 420, height: 120), context: context, label: "\(role.rawValue) bubble", expected: ["plain \(role.rawValue) fixture"], contentDrivenHeight: true, contentDrivenWidth: widthFollowsContent)
        }
        try await render(MessageBubble(message: ChatMessage(role: .assistant, content: "", thinking: "Reasoning in progress"), isStreaming: true, streamingThinkingOnly: true), size: NSSize(width: 420, height: 120), context: context, label: "reasoning-only bubble", expected: ["Reasoning in progress"], contentDrivenHeight: true)
        try await render(MessageBubble(message: ChatMessage(role: .assistant, content: ""), isStreaming: true), size: NSSize(width: 420, height: 120), context: context, label: "streaming dots", contentDrivenHeight: true)
        var replacements = 0
        var copies = 0
        var closes = 0
        let overlay = RewriteOverlayView(original: "Before", rewritten: "After", templateName: "Fixture", onReplace: { replacements += 1 }, onCopy: { copies += 1 }, onClose: { closes += 1 })
        try await render(overlay, size: NSSize(width: 420, height: 280), context: context, label: "rewrite overlay", expected: ["Fixture", "Replace", "Copy", "Close"], press: ["Replace", "Copy", "Close"])
        overlay.onReplace()
        overlay.onCopy()
        overlay.onClose()
        try context.equal([replacements, copies, closes], [2, 2, 2], "Overlay native controls and callbacks route actions")
        try attachments(context)
    }

    private static func render<V: View>(_ view: V, size: NSSize, context: CoverageContext, label: String, expected: [String] = [], press: [String] = [], contentDrivenHeight: Bool = false, contentDrivenWidth: Bool = false) async throws {
        OwnedAccessibility.materialize()
        let host = NSHostingView(rootView: view)
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -100000, y: -100000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Same teardown rule as UI2Hosted: no ordering animations, the
        // transform animation outliving a panel over-releases on dealloc
        // (measured run12 segfault).
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            // Drain pending CA transactions before the panel deallocs.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        settleOwnedView()
        host.layoutSubtreeIfNeeded()
        let elements = OwnedAccessibility.elements(in: host)
        let text = elements.flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.accessibilityValue() as? String].compactMap { $0 } }.joined(separator: "\n")
        for content in expected { try context.expect(text.contains(content), "\(label) exposes semantic content: \(content). Actual: \(text)") }
        for name in press {
            guard let control = elements.first(where: { $0.accessibilityLabel() == name || $0.accessibilityTitle() == name }) else { throw CoverageContext.Failure(description: "\(label): missing control \(name)") }
            try context.expect(control.accessibilityPerformPress(), "\(label): action \(name) handles press")
            settleOwnedView()
        }
        try context.expect(window.alphaValue == 0 && window.frame.maxX < 0 && window.frame.maxY < 0, "\(label) remains invisible and offscreen")
        try context.expect(!window.isKeyWindow && !window.isMainWindow, "\(label) does not take user focus")
        let fitting = host.fittingSize
        try context.expect(fitting.width.isFinite && fitting.height.isFinite && fitting.height > 0, "\(label) has finite nonzero content geometry")
        if contentDrivenWidth {
            try context.expect(abs(host.frame.width - fitting.width) <= 1 / window.backingScaleFactor, "\(label) width follows its actual intrinsic content: frame \(host.frame.width), fitting \(fitting.width)")
        } else {
            try context.equal(host.frame.width, size.width, "\(label) assigned width retained")
        }
        if contentDrivenHeight {
            try context.expect(abs(host.frame.height - fitting.height) <= 1 / window.backingScaleFactor, "\(label) height follows its actual intrinsic content: frame \(host.frame.height), fitting \(fitting.height)")
        } else {
            try context.equal(host.frame.height, size.height, "\(label) assigned viewport height retained")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CoverageContext.Failure(description: "\(label): cannot allocate render") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try context.expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "\(label) renders actual view pixels")
    }

    private static func settleOwnedView() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private static func attachments(_ context: CoverageContext) throws {
        let root = try context.temporaryDirectory("attachments")
        let url = root.appendingPathComponent("fixture.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: url)
        let uri = ChatAttachment.urlToDataURI(url)
        try context.expect(uri?.hasPrefix("data:image/png;base64,") == true, "Attachment MIME follows file extension")
        try context.equal(ChatAttachment.dataURIToImage(uri!)?.size, NSSize(width: 2, height: 2), "Attachment image round trip")
        try context.expect(ChatAttachment.urlToDataURI(root.appendingPathComponent("missing")) == nil, "Missing attachment rejected")
        try context.expect(ChatAttachment.dataURIToImage("invalid") == nil, "Malformed data URI rejected")
        try context.expect(ChatAttachment.dataURIToImage("data:image/png;base64,!") == nil, "Malformed base64 rejected")
        try context.expect(ChatAttachment.dataURIToImage("data:image/png;base64,\(Data("not an image".utf8).base64EncodedString())") == nil, "Non-image payload rejected")
    }
}
