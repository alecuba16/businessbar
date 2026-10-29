import AppKit
import BusinessBarCore
import SwiftUI

// MARK: - RewriteCoordinator

/// Orchestrates a rewrite: capture selection, pick template, stream the
/// completion, present the result overlay. Lives in the app target because
/// it drives UI; the LLM call itself is pure BusinessBarCore.
@MainActor
final class RewriteCoordinator: ObservableObject {
    static let shared = RewriteCoordinator()

    @Published var isStreaming = false
    @Published var errorMessage: String?

    private let selectionService: SelectionService
    private var streamTask: Task<Void, Never>?

    init(selectionService: SelectionService = SelectionService()) {
        self.selectionService = selectionService
    }

    /// Runs one template's rewrite on the current selection. Each template
    /// has its own global shortcut, so the template is fixed at trigger time.
    func startRewrite(template: PromptTemplate, client: LLMClient) {
        guard !isStreaming else { return }
        errorMessage = nil
        run(template: template, client: client)
    }

    private func run(template: PromptTemplate, client: LLMClient) {
        streamTask?.cancel()

        streamTask = Task { [weak self] in
            guard let self else { return }
            self.isStreaming = true
            // Rewrite is one shot: once the stream ends there is no further LLM
            // work here, so the shared ACP subprocess must not idle. Skipped
            // when the chat panel is open: it shares the process and session.
            defer {
                self.isStreaming = false
                if !CompanionPanelController.shared.isPanelVisible {
                    Task { await CompanionConfigService.shutdownACP() }
                }
            }

            // 1. Capture the selection before the panel/overlay takes focus.
            let capture = await self.selectionService.captureSelectedText()
            let selection: SelectionService.CapturedSelection?
            let original: String
            switch capture {
            case .success(let captured):
                selection = captured
                original = captured.text
                AppLogger.info("rewrite: captured \(captured.text.utf8.count) bytes viaAX=\(captured.viaAccessibility)", category: "Companion")
            case .failure(let error):
                selection = nil
                original = ""
                AppLogger.error("rewrite: capture failed \(error)", category: "Companion")
                self.errorMessage = Self.message(for: error)
                ToastCenter.shared.show(Self.message(for: error), icon: "exclamationmark.triangle", duration: 3.0)
                return
            }

            // 2. Render the template and stream the completion.
            let prompt = template.render(with: original)
            var result = ""
            do {
                // A template pinned to a local MLX model needs the server up
                // even when the chat panel's selected model is remote.
                try await CompanionConfigService.ensureLocalServer(forModelID: template.modelID)
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
                        ToastCenter.shared.show(message, icon: "exclamationmark.triangle", duration: 3.0)
                        return
                    case .cancelled:
                        return
                    case .toolCallRequested:
                        break
                    }
                }
            } catch {
                AppLogger.error("rewrite: stream error \(error.localizedDescription)", category: "Companion")
                self.errorMessage = error.localizedDescription
                ToastCenter.shared.show(error.localizedDescription, icon: "exclamationmark.triangle", duration: 3.0)
                return
            }

            guard !result.isEmpty else {
                self.errorMessage = "The model returned an empty response."
                ToastCenter.shared.show("The model returned an empty response.", icon: "exclamationmark.triangle", duration: 3.0)
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
                    AppLogger.info("rewrite: auto-replace for \(template.name)", category: "Companion")
                    let succeeded = await self.selectionService.replaceSelection(with: finalOutput)
                    if succeeded {
                        ToastCenter.shared.show("Replaced with \(template.name)", icon: "checkmark.circle", duration: 1.2)
                        return
                    }
                    AppLogger.error("rewrite: auto-replace AX write failed, showing overlay", category: "Companion")
                    ToastCenter.shared.show("Could not replace directly, review the result", icon: "exclamationmark.triangle", duration: 2.5)
                }
            case .append:
                if let selection, selection.viaAccessibility {
                    AppLogger.info("rewrite: insert-after for \(template.name)", category: "Companion")
                    let succeeded = await self.selectionService.insertAfterSelection(finalOutput)
                    if succeeded {
                        ToastCenter.shared.show("Inserted \(template.name) after selection", icon: "checkmark.circle", duration: 1.2)
                        return
                    }
                    AppLogger.error("rewrite: insert-after AX write failed, showing overlay", category: "Companion")
                    ToastCenter.shared.show("Could not insert directly, review the result", icon: "exclamationmark.triangle", duration: 2.5)
                }
            }

            RewriteOverlayController.shared.present(
                original: original,
                rewritten: finalOutput,
                templateName: template.name,
                selection: selection
            )
            ToastCenter.shared.show("Rewrite ready: \(template.name)", icon: "checkmark.circle", duration: 1.2)
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
