import Foundation

// MARK: - MLXRepoInspector

/// Validates a Hugging Face repo id for custom provisioning. The check is
/// explicit and user-initiated: nothing here runs until the user presses
/// Check in the local models sheet.
///
/// The repo must be MLX-format weights (mlx-community and similar). A
/// vanilla PyTorch repo cannot load in mlx-lm. The check fetches the repo
/// metadata and config.json, detects the format from the weight files and
/// the architectures field, and reports the model's tech details.
public enum MLXRepoInspector {
    public struct Report: Sendable, Equatable {
        /// Repo id, e.g. mlx-community/Qwen3-4B-Instruct-2507-4bit.
        public let repoID: String
        /// Human name derived from the repo id.
        public let displayName: String
        /// Total download size in bytes, from the HF API.
        public let sizeBytes: Int64
        /// Estimated resident RAM need while serving.
        public let ramBytes: Int64
        /// Input modality inferred from the architectures.
        public let kind: MLXModelCatalog.Kind
        /// Model architecture, e.g. Qwen3ForCausalLM.
        public let architecture: String
        /// Context window from max_position_embeddings, when present.
        public let contextLength: Int?
        /// Quantization label from config.json, when present.
        public let quantization: String?
        /// Reasoning capability detected from the chat template and config.
        public let reasoning: MLXReasoningCapability

        public init(
            repoID: String,
            displayName: String,
            sizeBytes: Int64,
            ramBytes: Int64,
            kind: MLXModelCatalog.Kind,
            architecture: String,
            contextLength: Int?,
            quantization: String?,
            reasoning: MLXReasoningCapability = .none
        ) {
            self.repoID = repoID
            self.displayName = displayName
            self.sizeBytes = sizeBytes
            self.ramBytes = ramBytes
            self.kind = kind
            self.architecture = architecture
            self.contextLength = contextLength
            self.quantization = quantization
            self.reasoning = reasoning
        }
    }

    public enum ValidationError: Error, Sendable, Equatable, LocalizedError {
        case badRepoID
        case repoNotFound
        case notMLXFormat
        case noWeightFiles
        case requestFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badRepoID:
                return "Enter a repo id like mlx-community/Model-4bit"
            case .repoNotFound:
                return "Repo not found on Hugging Face"
            case .notMLXFormat:
                return "Not an MLX-format repo. Pick a repo from mlx-community or another MLX conversion"
            case .noWeightFiles:
                return "The repo has no MLX weight files"
            case .requestFailed(let detail):
                return "Check failed: \(detail)"
            }
        }
    }

    /// Session used for the check. Injectable for tests.
    public static var session: URLSession = .shared

    /// Architectures that take image input. mlx-vlm serves these.
    static let visionArchitectures: Set<String> = [
        "Qwen2VLForConditionalGeneration",
        "Qwen2_5_VLForConditionalGeneration",
        "Qwen3VLForConditionalGeneration",
        "Qwen3_VLForConditionalGeneration",
        "LlavaForConditionalGeneration",
        "LlavaNextForConditionalGeneration",
        "Idefics3ForConditionalGeneration",
        "Idefics2ForConditionalGeneration",
        "Gemma3ForConditionalGeneration",
        "PaliGemmaForConditionalGeneration",
        "MllamaForConditionalGeneration",
        "PixtralForConditionalGeneration",
    ]

    /// Simple shape check: owner/name with no spaces or URL parts.
    public static func isValidRepoID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw, trimmed.contains("/") else { return false }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Human name from a repo id: mlx-community/Qwen3-4B -> Qwen3 4B.
    public static func displayName(fromRepoID repoID: String) -> String {
        let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
        var cleaned = name
        for suffix in ["-Instruct-4bit", "-Instruct-8bit", "-MLX-4bit", "-MLX", "-4bit", "-8bit"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        return cleaned.replacingOccurrences(of: "-", with: " ")
    }

    /// RAM estimate for a serving model: weights resident plus activation
    /// and KV-cache headroom. Curated entries use roughly 1.3x to 1.6x the
    /// on-disk size, so the same ratio band applies here.
    public static func estimateRAM(sizeBytes: Int64) -> Int64 {
        max(sizeBytes + sizeBytes / 2, sizeBytes)
    }

    /// True when the repo ships MLX weight files. MLX repos carry
    /// .safetensors shards (never .bin) and a config.json.
    public static func isMLXFormat(siblings: [[String: Any]]) -> Bool {
        let names = siblings.compactMap { $0["rfilename"] as? String }
        let hasSafetensors = names.contains { $0.hasSuffix(".safetensors") }
        let hasPyTorchWeights = names.contains { $0.hasSuffix(".bin") || $0.hasSuffix(".pt") }
        return hasSafetensors && !hasPyTorchWeights
    }

    /// Vision kind from the config architectures. Unknown architectures
    /// default to text: mlx-lm serves them or fails loudly at start.
    public static func kind(architecture: String) -> MLXModelCatalog.Kind {
        visionArchitectures.contains(architecture) ? .textAndImages : .text
    }

    /// Fetches the repo metadata and config.json, validates the MLX
    /// format, and builds the report. This is the only network path in
    /// custom provisioning and it runs only on Check.
    public static func check(repoID: String) async throws -> Report {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRepoID(trimmed) else {
            throw ValidationError.badRepoID
        }

        let api = URL(string: "https://huggingface.co/api/models/\(trimmed)")!
        var request = URLRequest(url: api)
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ValidationError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ValidationError.requestFailed("unexpected response")
        }
        guard http.statusCode != 404 else {
            throw ValidationError.repoNotFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ValidationError.requestFailed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]]
        else {
            throw ValidationError.requestFailed("unexpected repo payload")
        }
        guard isMLXFormat(siblings: siblings) else {
            throw ValidationError.notMLXFormat
        }

        let sizeBytes = Int64(json["usedStorage"] as? Double ?? json["size"] as? Double ?? 0)
        let architectures = ((json["config"] as? [String: Any])?["architectures"] as? [String]) ?? []
        let architecture = architectures.first ?? "unknown"

        // config.json carries the context window and quantization details.
        var contextLength: Int?
        var quantization: String?
        var configJSON: [String: Any]?
        if let fetchedConfig = await fetchConfigJSON(repoID: trimmed) {
            configJSON = fetchedConfig
            contextLength = fetchedConfig["max_position_embeddings"] as? Int
            if let quant = fetchedConfig["quantization"] as? [String: Any] {
                let bits = quant["bits"] as? Int
                let group = quant["group_size"] as? Int
                if let bits {
                    quantization = group.map { "\(bits)-bit, group \( $0)" } ?? "\(bits)-bit"
                }
            }
        }

        // The chat template decides the reasoning shape. Newer Qwen3
        // repos ship it as a standalone chat_template.jinja instead of
        // inside tokenizer_config.json, so the standalone file is fetched
        // first; the JSON layouts follow. Config and architecture act as
        // fallbacks.
        var chatTemplate: String?
        if let raw = await fetchRawText(repoID: trimmed, file: "chat_template.jinja"),
           !raw.isEmpty {
            chatTemplate = raw
        } else {
            for file in ["chat_template.json", "tokenizer_config.json"] {
                if let json = await fetchConfigJSON(repoID: trimmed, file: file),
                   let template = (json["chat_template"] as? String)
                    ?? (json["chat_template_jinja"] as? String),
                   !template.isEmpty {
                    chatTemplate = template
                    break
                }
            }
        }
        let reasoning = MLXReasoningInspector.capability(
            chatTemplate: chatTemplate,
            configJSON: configJSON,
            architecture: architecture
        )

        let ramBytes = estimateRAM(sizeBytes: sizeBytes)
        return Report(
            repoID: trimmed,
            displayName: displayName(fromRepoID: trimmed),
            sizeBytes: sizeBytes,
            ramBytes: ramBytes,
            kind: kind(architecture: architecture),
            architecture: architecture,
            contextLength: contextLength,
            quantization: quantization,
            reasoning: reasoning
        )
    }

    /// Fetches and decodes a JSON file from the repo root.
    static func fetchConfigJSON(repoID: String, file: String = "config.json") async -> [String: Any]? {
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Fetches a raw text file from the repo root, for standalone jinja
    /// chat templates that are not JSON.
    static func fetchRawText(repoID: String, file: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}