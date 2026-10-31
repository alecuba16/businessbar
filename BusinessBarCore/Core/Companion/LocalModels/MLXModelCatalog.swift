import Foundation

// MARK: - MLXModelCatalog

/// Curated on-device MLX models. Downloads happen only through the explicit
/// download flow in preferences; nothing here touches the network.
public enum MLXModelCatalog {
    /// What a catalog model accepts as input. Vision models run through
    /// mlx-vlm's OpenAI-compatible server; text models through mlx-lm's.
    public enum Kind: String, Sendable, Hashable, Codable {
        case text
        case textAndImages

        public var label: String {
            switch self {
            case .text: return "Text"
            case .textAndImages: return "Text + Images"
            }
        }
    }

    public struct Entry: Identifiable, Sendable, Hashable, Codable {
        public let id: String
        public let displayName: String
        /// Approximate download size on disk, bytes.
        public let sizeBytes: Int64
        /// Rough resident-RAM need while serving, bytes.
        public let ramBytes: Int64
        /// Input modality; decides the server package that serves it.
        public let kind: Kind
        /// Reasoning capability detected from the repo's chat template and
        /// config. Nil on stored entries predating detection: unknown, not
        /// absent. Refreshed from the snapshot after download.
        public let reasoning: MLXReasoningCapability?

        public init(
            id: String,
            displayName: String,
            sizeBytes: Int64,
            ramBytes: Int64,
            kind: Kind,
            reasoning: MLXReasoningCapability? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.sizeBytes = sizeBytes
            self.ramBytes = ramBytes
            self.kind = kind
            self.reasoning = reasoning
        }

        private enum CodingKeys: String, CodingKey {
            case id, displayName, sizeBytes, ramBytes, kind, reasoning
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
            ramBytes = try container.decode(Int64.self, forKey: .ramBytes)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
            reasoning = try container.decodeIfPresent(MLXReasoningCapability.self, forKey: .reasoning)
        }
    }

    public enum Fit: String, Sendable {
        case fits
        case mayBeSlow
        case wontFit

        public var label: String {
            switch self {
            case .fits: return "Fits"
            case .mayBeSlow: return "May be slow"
            case .wontFit: return "Won't fit"
            }
        }
    }

    public static let entries: [Entry] = [
        Entry(
            id: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen3 0.6B",
            sizeBytes: 420_000_000,
            ramBytes: 850_000_000,
            kind: .text
        ),
        Entry(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B Instruct",
            sizeBytes: 660_000_000,
            ramBytes: 1_100_000_000,
            kind: .text
        ),
        Entry(
            id: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            displayName: "Qwen3-VL 2B",
            sizeBytes: 1_700_000_000,
            ramBytes: 4_400_000_000,
            kind: .textAndImages
        ),
        Entry(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct",
            sizeBytes: 1_930_000_000,
            ramBytes: 2_700_000_000,
            kind: .text
        ),
        Entry(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B Instruct",
            sizeBytes: 2_350_000_000,
            ramBytes: 3_200_000_000,
            kind: .text
        ),
        Entry(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen3-VL 4B",
            sizeBytes: 3_090_000_000,
            ramBytes: 6_000_000_000,
            kind: .textAndImages
        ),
        Entry(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 7B",
            sizeBytes: 4_060_000_000,
            ramBytes: 5_000_000_000,
            kind: .text
        ),
        Entry(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            sizeBytes: 4_600_000_000,
            ramBytes: 5_500_000_000,
            kind: .text
        ),
    ]

    public static func entry(id: String, defaults: UserDefaults = .standard) -> Entry? {
        entries.first { $0.id == id } ?? customEntries(defaults: defaults).first { $0.id == id }
    }

    // MARK: Custom entries

    /// User-added repos, persisted so the catalog survives restarts.
    /// Stored in UserDefaults as a JSON array; sizes and kind come from
    /// the repo check at add time.
    public static var customEntries: [Entry] {
        get { customEntries(defaults: .standard) }
        set { setCustomEntries(newValue, defaults: .standard) }
    }

    public static func customEntries(defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: customEntriesKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    public static func setCustomEntries(_ entries: [Entry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: customEntriesKey)
    }

    private static let customEntriesKey = "companionMLXCustomEntries"

    /// Adds a custom entry unless the repo id already exists. Returns the
    /// final entry list.
    @discardableResult
    public static func addCustomEntry(_ entry: Entry, defaults: UserDefaults = .standard) -> [Entry] {
        var current = customEntries(defaults: defaults)
        guard !current.contains(where: { $0.id == entry.id }) else { return current }
        current.append(entry)
        setCustomEntries(current, defaults: defaults)
        return current
    }

    /// Removes a custom entry by repo id. Curated entries cannot be
    /// removed through this path. Also clears the active model when it
    /// pointed at the removed repo.
    public static func removeCustomEntry(id: String, defaults: UserDefaults = .standard) {
        setCustomEntries(customEntries(defaults: defaults).filter { $0.id != id }, defaults: defaults)
        if MLXServerConfig.activeModelID(defaults: defaults) == id {
            MLXServerConfig.setActiveModelID(nil, defaults: defaults)
        }
    }

    /// Curated entries carry no reasoning metadata by default: it is
    /// discovered from the downloaded snapshot (or the Check flow for
    /// custom repos) and kept in the store, so a template fix upstream
    /// reaches users without an app update.
    public static func reasoningCapability(id modelID: String, defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) -> MLXReasoningCapability {
        if let entry = entry(id: modelID, defaults: defaults), let reasoning = entry.reasoning {
            return reasoning
        }
        if let override = reasoningOverrides(defaults: defaults)[modelID] {
            return override
        }
        if isDownloaded(modelID: modelID, home: home) {
            // Probe once, then remember: rows and pickers call this every
            // render, the snapshot read must not run each time.
            let capability = MLXReasoningInspector.capabilityFromSnapshot(modelID: modelID, home: home)
            setReasoningCapability(id: modelID, capability, defaults: defaults)
            return capability
        }
        return .none
    }

    /// Stores a discovered capability on a custom entry, or records it in
    /// the discovered-overrides table for curated entries (their list is
    /// compile-time and cannot be edited in place).
    public static func setReasoningCapability(
        id modelID: String,
        _ capability: MLXReasoningCapability,
        defaults: UserDefaults = .standard
    ) {
        if let index = customEntries(defaults: defaults).firstIndex(where: { $0.id == modelID }) {
            var updated = customEntries(defaults: defaults)
            let old = updated[index]
            updated[index] = Entry(
                id: old.id,
                displayName: old.displayName,
                sizeBytes: old.sizeBytes,
                ramBytes: old.ramBytes,
                kind: old.kind,
                reasoning: capability
            )
            setCustomEntries(updated, defaults: defaults)
        } else {
            var overrides = reasoningOverrides(defaults: defaults)
            overrides[modelID] = capability
            if let data = try? JSONEncoder().encode(overrides) {
                defaults.set(data, forKey: reasoningOverridesKey)
            }
        }
    }

    private static let reasoningOverridesKey = "companionMLXReasoningOverrides"

    private static func reasoningOverrides(defaults: UserDefaults) -> [String: MLXReasoningCapability] {
        guard let data = defaults.data(forKey: reasoningOverridesKey),
              let decoded = try? JSONDecoder().decode([String: MLXReasoningCapability].self, from: data)
        else { return [:] }
        return decoded
    }

    /// True when the repo id belongs to the curated list.
    public static func isCurated(id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Fit pill against installed RAM. The model needs ramBytes resident
    /// plus headroom for the rest of the system; generous margins because a
    /// menu bar app should never push the machine into swap.
    public static func fit(ramBytes: Int64, installedRAM: Int64) -> Fit {
        if installedRAM >= ramBytes * 3 { return .fits }
        if installedRAM >= ramBytes * 2 { return .mayBeSlow }
        return .wontFit
    }

    /// HF cache directory for a repo id, e.g.
    /// ~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-Instruct-4bit
    public static func cacheDirectory(
        modelID: String,
        home: String = NSHomeDirectory()
    ) -> URL {
        let repoDir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(repoDir)
    }

    /// Files a downloaded MLX model always has at the snapshot root. The
    /// download is only considered complete when all of them resolve.
    public static let requiredFiles = ["config.json", "tokenizer_config.json"]

    /// True when the model has a complete snapshot in the HF cache. Partial
    /// downloads land in the same directory with .incomplete suffixes, so
    /// the required-files check catches interrupted downloads.
    public static func isDownloaded(modelID: String, home: String = NSHomeDirectory()) -> Bool {
        let dir = cacheDirectory(modelID: modelID, home: home)
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("snapshots"),
            includingPropertiesForKeys: nil
        ), let snapshot = snapshots.first else {
            return false
        }
        return requiredFiles.allSatisfy { name in
            var isDir: ObjCBool = false
            let path = snapshot.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Bytes the model occupies in the HF cache, for delete previews and
    /// download progress. 0 when nothing is there yet.
    public static func downloadedBytes(modelID: String, home: String = NSHomeDirectory()) -> Int64 {
        directorySize(cacheDirectory(modelID: modelID, home: home))
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}