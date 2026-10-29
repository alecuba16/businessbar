import Foundation

// MARK: - MLXReasoningCapability

/// What a local MLX model can do on the reasoning axis, discovered from its
/// own repo files (chat template, config) instead of guessed from the name.
///
/// Two shapes exist in the wild:
/// - Toggle models (Qwen3 family): thinking is on or off, no levels in
///   between. The chat template takes an `enable_thinking` argument.
/// - Effort models (gpt-oss family): the chat template takes a
///   `reasoning_effort` argument with discrete levels.
///
/// mlx-lm's server passes `chat_template_kwargs` from the request body into
/// the template, so both shapes map onto request fields we control.
public struct MLXReasoningCapability: Sendable, Equatable, Codable {
    public enum Shape: String, Sendable, Equatable, Codable {
        /// Template takes `enable_thinking` (Qwen3 style): on/off toggle.
        case thinkingToggle
        /// Template takes `reasoning_effort` (gpt-oss style): discrete levels.
        case effortLevels
    }

    public let supported: Bool
    public let shape: Shape
    /// Effort levels the template accepts; empty for toggle models.
    public let effortOptions: [String]

    public init(supported: Bool, shape: Shape, effortOptions: [String]) {
        self.supported = supported
        self.shape = shape
        self.effortOptions = effortOptions
    }

    /// Capability for models that show no reasoning markers at all.
    public static let none = MLXReasoningCapability(
        supported: false,
        shape: .effortLevels,
        effortOptions: []
    )

    /// Chat template kwargs for the local server request, derived from the
    /// reasoning toggle and the stored effort pick.
    ///
    /// Toggle models (Qwen3): thinking is on by default in the template, so
    /// kwargs are sent only to turn it off (toggle off, or effort picked as
    /// none/minimal). Effort models (gpt-oss): reasoning cannot be turned
    /// off, so the toggle off clamps to the lowest level and an unknown or
    /// missing effort falls back to the template default (medium).
    public func requestKwargs(reasoningEnabled: Bool, effort: String?) -> [String: Any]? {
        guard supported else { return nil }
        switch shape {
        case .thinkingToggle:
            let off = !reasoningEnabled
                || effort == "none" || effort == "minimal" || effort == "off"
            return off ? ["enable_thinking": false] : nil
        case .effortLevels:
            let resolved = reasoningEnabled
                ? (effort.flatMap { effortOptions.contains($0) ? $0 : nil } ?? "medium")
                : "low"
            return ["reasoning_effort": resolved]
        }
    }
}

// MARK: - MLXReasoningInspector

/// Detects reasoning support from a model's own files. Works on two inputs:
/// - The Check flow (repo not downloaded yet): `tokenizerConfigJSON` fetched
///   from Hugging Face by the repo inspector.
/// - After download (files on disk): the snapshot's `tokenizer_config.json`
///   is one of `MLXModelCatalog.requiredFiles`, so it always exists when the
///   download counts as complete.
public enum MLXReasoningInspector {
    /// Effort levels gpt-oss templates accept; harmony format has exactly
    /// these three.
    public static let gptOssEffortLevels = ["low", "medium", "high"]

    /// Config architectures that use the harmony format with a
    /// reasoning_effort template argument.
    static let effortArchitectures: Set<String> = [
        "GptOssForCausalLM",
        "GPTOssForCausalLM",
    ]

    /// Detects the capability from a chat template string, a config.json
    /// dictionary, and the model architecture. The chat template carries the
    /// truth: `enable_thinking` marks a toggle model, `reasoning_effort`
    /// marks an effort model. Config and architecture are fallbacks when the
    /// template is missing or uninformative.
    public static func capability(
        chatTemplate: String?,
        configJSON: [String: Any]?,
        architecture: String
    ) -> MLXReasoningCapability {
        // gpt-oss: the template names the kwarg and the effort table is
        // known, so the effort shape wins over the generic thinking markers.
        if effortArchitectures.contains(architecture)
            || (chatTemplate?.contains("reasoning_effort") == true) {
            return MLXReasoningCapability(
                supported: true,
                shape: .effortLevels,
                effortOptions: gptOssEffortLevels
            )
        }

        if let template = chatTemplate {
            if template.contains("enable_thinking") {
                return MLXReasoningCapability(
                    supported: true,
                    shape: .thinkingToggle,
                    effortOptions: []
                )
            }
            // Thinking markers without the toggles: the model thinks but the
            // template offers no way to turn it off or dial it. Still worth
            // reporting as a thinking model so the UI can show the reasoning
            // toggle; the request side just never sends kwargs.
            if template.contains("<think>") || template.contains("<|thinking|>")
                || template.contains("begin_of_think")
                || template.contains("begin▁of▁think") {
                return MLXReasoningCapability(
                    supported: true,
                    shape: .thinkingToggle,
                    effortOptions: []
                )
            }
        }

        // Some configs expose reasoning through custom fields (e.g. NovaAct,
        // Qwen3 distills on HF). Treat known keys as a thinking toggle when
        // the template said nothing.
        if let config = configJSON {
            for key in ["reasoning", "thinking", "enable_thinking"] {
                if config[key] is Bool {
                    return MLXReasoningCapability(
                        supported: true,
                        shape: .thinkingToggle,
                        effortOptions: []
                    )
                }
            }
        }

        return .none
    }

    /// Reads the capability from a downloaded model's snapshot directory:
    /// `tokenizer_config.json` (chat template) plus `config.json`
    /// (architecture). Returns .none when files are missing, the same value
    /// the Check flow would report for a repo without reasoning markers.
    public static func capabilityFromSnapshot(
        modelID: String,
        home: String = NSHomeDirectory()
    ) -> MLXReasoningCapability {
        let repoDir = MLXModelCatalog.cacheDirectory(modelID: modelID, home: home)
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: repoDir.appendingPathComponent("snapshots"),
            includingPropertiesForKeys: nil
        ), let snapshot = snapshots.first else {
            return .none
        }

        let tokenizerConfig = decodeJSON(
            snapshot.appendingPathComponent("tokenizer_config.json")
        )
        let config = decodeJSON(snapshot.appendingPathComponent("config.json"))
        let template = (tokenizerConfig?["chat_template"] as? String)
            ?? (tokenizerConfig?["chat_template_jinja"] as? String)
        let architectures = (config?["architectures"] as? [String]) ?? []
        return capability(
            chatTemplate: template,
            configJSON: config,
            architecture: architectures.first ?? "unknown"
        )
    }

    private static func decodeJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}