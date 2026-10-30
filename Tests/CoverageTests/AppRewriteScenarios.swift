import BusinessBarCore
import Foundation
@testable import BusinessBar

@MainActor
enum AppRewriteScenarios {
    static func run(_ context: CoverageContext) async throws {
        for (error, message) in [
            (SelectionService.CaptureError.emptySelection, "No text is selected."),
            (.captureFailed, "Could not read the selected text in this app."),
            (.accessibilityNotTrusted, "BusinessBar needs Accessibility permission")
        ] {
            let source = RewriteFixtureSelection(result: .failure(error))
            let output = RewriteFixtureOutput()
            let coordinator = RewriteCoordinator(selectionService: source, effects: output.effects)
            coordinator.startRewrite(template: PromptTemplate(name: "Fixture", prompt: "[placeholder]"), client: RewriteFixtureClient(events: []))
            try await settle(coordinator, context)
            try context.expect(coordinator.errorMessage?.hasPrefix(message) == true, "Capture failure message \(error)")
            try context.equal(output.toasts.count, 1, "Capture failure emits one toast")
            try context.equal(output.prepared.count, 0, "Capture failure does not prepare model")
            try context.equal(output.finishes, 1, "Capture failure finishes lifecycle")
            try context.expect(output.presentations.isEmpty, "Capture failure never presents result")
        }
        let cases: [(TemplateAction, Bool, Bool, String, String, String?, Bool)] = [
            (.overlay, true, true, "original", "<output>rewritten</output>", nil, true),
            (.replace, true, true, "original", "<output>rewritten</output>", "rewritten", false),
            (.replace, true, false, "original", "<output>rewritten</output>", "rewritten", true),
            (.replace, true, true, "original", "untagged", nil, true),
            (.replace, false, true, "original", "<output>rewritten</output>", nil, true),
            (.append, true, true, "original", "<output>rewritten</output>", "rewritten", false),
            (.append, true, false, "original", "<output>rewritten</output>", "rewritten", true),
            (.appendLineBreak, true, true, "original", "<output>rewritten</output>", "\nrewritten", false),
            (.appendLineBreak, true, true, "original\n", "<output>rewritten</output>", "rewritten", false),
            (.append, false, true, "original", "<output>rewritten</output>", nil, true),
            (.overlay, true, true, "original", "<output></output>", nil, true)
        ]
        for (action, viaAX, succeeded, original, response, write, presents) in cases {
            let source = RewriteFixtureSelection(result: .success(.init(text: original, viaAccessibility: viaAX, ownerProcessIdentifier: 0)))
            source.writeSucceeds = succeeded
            let output = RewriteFixtureOutput()
            let modelID = UUID()
            let template = PromptTemplate(name: "Fixture", prompt: "Rewrite [placeholder]", action: action, reasoningEffort: "high", modelID: modelID)
            let client = RewriteFixtureClient(events: [.thinkingDelta("not output"), .delta("ignored partial"), .toolCallRequested(name: "ignored", argumentsJSON: "{}"), .finished(fullText: response)])
            let coordinator = RewriteCoordinator(selectionService: source, effects: output.effects)
            coordinator.startRewrite(template: template, client: client)
            coordinator.startRewrite(template: template, client: client)
            try context.expect(coordinator.isStreaming, "Rewrite starts synchronously")
            try await settle(coordinator, context)
            try context.expect(coordinator.errorMessage == nil, "Rewrite completes without error")
            try context.equal(source.captures, 1, "Duplicate trigger ignored")
            try context.equal(output.prepared, [modelID], "Pinned model preparation injected")
            try context.equal(client.messages.first?.content, "Rewrite \(original)", "Template renders actual captured text")
            try context.equal(client.effort, "high", "Template effort forwarded")
            let writes = action == .replace ? source.replacements : source.insertions
            try context.equal(writes, write.map { [$0] } ?? [], "Rewrite write action \(action)")
            try context.equal(!output.presentations.isEmpty, presents, "Overlay fallback policy \(action)")
            if let presentation = output.presentations.first {
                try context.equal(presentation.original, original, "Overlay original preserved")
                try context.equal(presentation.rewritten, response == "<output></output>" ? response : (response == "untagged" ? "untagged" : "rewritten"), "Overlay contains raw captured output only")
                try context.equal(presentation.template, "Fixture", "Overlay template label")
            }
            try context.equal(output.finishes, 1, "Successful rewrite releases lifecycle once")
        }
        for (events, failure, expectedError) in [
            ([CompanionEvent.failed("controlled failure")], false, "controlled failure"),
            ([], false, "The model returned an empty response."),
            ([.cancelled], false, nil),
            ([], true, "controlled rewrite error")
        ] {
            let source = RewriteFixtureSelection(result: .success(.init(text: "text", viaAccessibility: true, ownerProcessIdentifier: 0)))
            let output = RewriteFixtureOutput()
            let coordinator = RewriteCoordinator(selectionService: source, effects: output.effects)
            coordinator.startRewrite(template: PromptTemplate(name: "Fixture", prompt: "[placeholder]"), client: RewriteFixtureClient(events: events, fails: failure))
            try await settle(coordinator, context)
            try context.equal(coordinator.errorMessage, expectedError, "Rewrite terminal failure/cancel state")
            try context.expect(output.presentations.isEmpty && source.replacements.isEmpty, "Failure/cancel does not write or present")
            coordinator.cancel()
        }
        let source = RewriteFixtureSelection(result: .success(.init(text: "text", viaAccessibility: true, ownerProcessIdentifier: 0)))
        let output = RewriteFixtureOutput()
        output.preparationFails = true
        let coordinator = RewriteCoordinator(selectionService: source, effects: output.effects)
        coordinator.startRewrite(template: PromptTemplate(name: "Fixture", prompt: "[placeholder]"), client: RewriteFixtureClient(events: [.finished(fullText: "never")]))
        try await settle(coordinator, context)
        try context.equal(coordinator.errorMessage, "controlled rewrite error", "Preparation failure surfaced")
        try context.expect(output.presentations.isEmpty, "Preparation failure never presents")
    }

    private static func settle(_ coordinator: RewriteCoordinator, _ context: CoverageContext) async throws {
        for _ in 0..<1000 {
            if !coordinator.isStreaming { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(false, "Rewrite failed to settle")
    }
}

private final class RewriteFixtureSelection: RewriteSelectionSource, @unchecked Sendable {
    let result: Result<SelectionService.CapturedSelection, SelectionService.CaptureError>
    var writeSucceeds = true
    var captures = 0
    var replacements: [String] = []
    var insertions: [String] = []
    init(result: Result<SelectionService.CapturedSelection, SelectionService.CaptureError>) { self.result = result }
    func captureSelectedText() async -> Result<SelectionService.CapturedSelection, SelectionService.CaptureError> { captures += 1; return result }
    func replaceSelection(with text: String) async -> Bool { replacements.append(text); return writeSucceeds }
    func insertAfterSelection(_ text: String) async -> Bool { insertions.append(text); return writeSucceeds }
}

@MainActor
private final class RewriteFixtureOutput {
    struct Presentation { let original: String; let rewritten: String; let template: String }
    var finishes = 0
    var preparationFails = false
    var prepared: [UUID?] = []
    var toasts: [String] = []
    var presentations: [Presentation] = []
    var effects: RewriteCoordinator.Effects {
        .init(prepareModel: { [self] id in
            prepared.append(id)
            if preparationFails { throw RewriteFixtureError() }
        }, finished: { [self] in finishes += 1 }, toast: { [self] text, _, _ in toasts.append(text) }, present: { [self] original, rewritten, template, _ in
            presentations.append(.init(original: original, rewritten: rewritten, template: template))
        }, log: { _, _ in })
    }
}

private struct RewriteFixtureError: LocalizedError {
    var errorDescription: String? { "controlled rewrite error" }
}

private final class RewriteFixtureClient: LLMClient, @unchecked Sendable {
    let name = "Rewrite fixture"
    let events: [CompanionEvent]
    let fails: Bool
    var messages: [ChatMessage] = []
    var effort: String?
    init(events: [CompanionEvent], fails: Bool = false) { self.events = events; self.fails = fails }
    func stream(messages: [ChatMessage], onToolCall: ((String, String) async -> String)?, reasoningEffortOverride: String?) async -> AsyncThrowingStream<CompanionEvent, Error> {
        self.messages = messages
        effort = reasoningEffortOverride
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if fails { continuation.finish(throwing: RewriteFixtureError()) } else { continuation.finish() }
        }
    }
}
