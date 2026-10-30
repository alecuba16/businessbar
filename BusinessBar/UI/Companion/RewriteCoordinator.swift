import AppKit
import BusinessBarCore
import SwiftUI

// MARK: - RewriteCoordinator

/// Orchestrates a rewrite: capture selection, pick template, stream the
/// completion, present the result overlay. Lives in the app target because
/// it drives UI; the LLM call itself is pure BusinessBarCore.
protocol RewriteSelectionSource {
    func captureSelectedText() async -> Result<SelectionService.CapturedSelection, SelectionService.CaptureError>
    func replaceSelection(with text: String) async -> Bool
    func insertAfterSelection(_ text: String) async -> Bool
}

extension SelectionService: RewriteSelectionSource {}

@MainActor
final class RewriteCoordinator: ObservableObject {
    static let shared = RewriteCoordinator()

    @Published var isStreaming = false
    @Published var errorMessage: String?

    @MainActor
    struct Effects {
        var prepareModel: @MainActor (UUID?) async throws -> Void
        var finished: @MainActor () -> Void
        var toast: @MainActor (String, String, TimeInterval) -> Void
        var present: @MainActor (String, String, String, SelectionService.CapturedSelection?) -> Void
        var log: @MainActor (String, Bool) -> Void

        static var live: Effects {
            Effects(
                prepareModel: { try await CompanionConfigService.ensureLocalServer(forModelID: $0) },
                finished: {
                    if !CompanionPanelController.shared.isPanelVisible {
                        Task { await CompanionConfigService.shutdownACP() }
                    }
                },
                toast: { ToastCenter.shared.show($0, icon: $1, duration: $2) },
                present: { RewriteOverlayController.shared.present(original: $0, rewritten: $1, templateName: $2, selection: $3) },
                log: { message, error in
                    if error { AppLogger.error(message, category: "Companion") }
                    else { AppLogger.info(message, category: "Companion") }
                }
            )
        }
    }

    private let selectionService: any RewriteSelectionSource
    private let effects: Effects
    private var streamTask: Task<Void, Never>?

    init(selectionService: any RewriteSelectionSource = SelectionService(), effects: Effects? = nil) {
        self.selectionService = selectionService
        self.effects = effects ?? .live
    }

    /// Runs one template's rewrite on the current selection. Each template
    /// has its own global shortcut, so the template is fixed at trigger time.
    func startRewrite(template: PromptTemplate, client: LLMClient) {
        // The flag flips here, not in the task body: a duplicate trigger in
        // the same runloop turn must hit the guard before any body runs, or
        // the second run cancels the first mid-stream and the cancelled
        // stream ends empty, surfacing a false "empty response" toast.
        guard !isStreaming else { return }
        isStreaming = true
        errorMessage = nil
        run(template: template, client: client)
    }

    private func run(template: PromptTemplate, client: LLMClient) {
        streamTask?.cancel()

        streamTask = Task { [weak self] in
            guard let self else { return }
            // Rewrite is one shot: once the stream ends there is no further LLM
            // work here, so the shared ACP subprocess must not idle. Skipped
            // when the chat panel is open: it shares the process and session.
            defer {
                self.isStreaming = false
                self.effects.finished()
            }

            // 1. Capture the selection before the panel/overlay takes focus.
            let capture = await self.selectionService.captureSelectedText()
            let selection: SelectionService.CapturedSelection?
            let original: String
            switch capture {
            case .success(let captured):
                selection = captured
                original = captured.text
                self.effects.log("rewrite: captured \(captured.text.utf8.count) bytes viaAX=\(captured.viaAccessibility)", false)
            case .failure(let error):
                selection = nil
                original = ""
                self.effects.log("rewrite: capture failed \(error)", true)
                self.errorMessage = Self.message(for: error)
                self.effects.toast(Self.message(for: error), "exclamationmark.triangle", 3.0)
                return
            }

            // 2. Render the template and stream the completion.
            let prompt = template.render(with: original)
            var result = ""
            do {
                // A template pinned to a local MLX model needs the server up
                // even when the chat panel's selected model is remote.
                try await self.effects.prepareModel(template.modelID)
                let stream = await client.stream(messages: [
                    ChatMessage(role: .user, content: prompt)
                ], onToolCall: nil, reasoningEffortOverride: template.reasoningEffort)
                for try await event in stream {
                    switch event {
                    case .delta(let text):
                        result += text
                    case .thinkingDelta:
                        // Reasoning never feeds the rewrite output.
                        break
                    case .finished(let fullText):
                        result = fullText
                    case .failed(let message):
                        self.errorMessage = message
                        self.effects.toast(message, "exclamationmark.triangle", 3.0)
                        return
                    case .cancelled:
                        return
                    case .toolCallRequested:
                        break
                    }
                }
            } catch {
                self.effects.log("rewrite: stream error \(error.localizedDescription)", true)
                self.errorMessage = error.localizedDescription
                self.effects.toast(error.localizedDescription, "exclamationmark.triangle", 3.0)
                return
            }

            guard !result.isEmpty else {
                self.errorMessage = "The model returned an empty response."
                self.effects.toast("The model returned an empty response.", "exclamationmark.triangle", 3.0)
                return
            }

            // Keep only the raw output: templates ask the model to wrap the
            // result in <output> tags, and commentary outside them is dropped.
            // A capture that produced nothing falls back to the raw reply.
            let tagged = RewriteOutputCapture.containsOutputTags(result)
            let output = RewriteOutputCapture.capture(from: result)
            let finalOutput = output.isEmpty ? result : output

            // 3. Dispatch on the template action. Insert-after and replace
            // need an AX-replaceable selection; anything else (or a failed
            // direct write) falls back to the overlay so the result is
            // never lost.
            switch template.action {
            case .overlay:
                break
            case .replace:
                if tagged, let selection, selection.viaAccessibility {
                    self.effects.log("rewrite: auto-replace for \(template.name)", false)
                    let succeeded = await self.selectionService.replaceSelection(with: finalOutput)
                    if succeeded {
                        self.effects.toast("Replaced with \(template.name)", "checkmark.circle", 1.2)
                        return
                    }
                    self.effects.log("rewrite: auto-replace AX write failed, showing overlay", true)
                    self.effects.toast("Could not replace directly, review the result", "exclamationmark.triangle", 2.5)
                }
            case .append, .appendLineBreak:
                if let selection, selection.viaAccessibility {
                    // One leading newline puts the reply on the line below
                    // the selection; a selection already ending in a newline
                    // would leave a blank line, so it is not doubled.
                    let text = template.action == .appendLineBreak && !original.hasSuffix("\n")
                        ? "\n" + finalOutput
                        : finalOutput
                    self.effects.log("rewrite: insert-after for \(template.name)", false)
                    let succeeded = await self.selectionService.insertAfterSelection(text)
                    if succeeded {
                        self.effects.toast("Inserted \(template.name) after selection", "checkmark.circle", 1.2)
                        return
                    }
                    self.effects.log("rewrite: insert-after AX write failed, showing overlay", true)
                    self.effects.toast("Could not insert directly, review the result", "exclamationmark.triangle", 2.5)
                }
            }

            self.effects.present(original, finalOutput, template.name, selection)
            self.effects.toast("Rewrite ready: \(template.name)", "checkmark.circle", 1.2)
        }
    }

    func cancel() {
        streamTask?.cancel()
    }

    private static func message(for error: SelectionService.CaptureError) -> String {
        switch error {
        case .emptySelection: return "No text is selected."
        case .captureFailed: return "Could not read the selected text in this app."
        case .accessibilityNotTrusted:
            return "BusinessBar needs Accessibility permission to read the selection. Enable it in System Settings > Privacy & Security > Accessibility."
        }
    }
}
