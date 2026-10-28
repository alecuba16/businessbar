import Foundation

// MARK: - MLXModelCatalog

/// Curated on-device MLX models. Downloads happen only through the explicit
/// download flow in preferences; nothing here touches the network.
public enum MLXModelCatalog {
    public struct Entry: Identifiable, Sendable, Hashable {
        public let id: String
        public let displayName: String
        /// Approximate download size on disk, bytes.
        public let sizeBytes: Int64
        /// Rough resident-RAM need while serving, bytes.
        public let ramBytes: Int64

        public init(id: String, displayName: String, sizeBytes: Int64, ramBytes: Int64) {
            self.id = id
            self.displayName = displayName
            self.sizeBytes = sizeBytes
            self.ramBytes = ramBytes
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
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B Instruct",
            sizeBytes: 660_000_000,
            ramBytes: 1_100_000_000
        ),
        Entry(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct",
            sizeBytes: 1_930_000_000,
            ramBytes: 2_700_000_000
        ),
        Entry(
            id: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen3 0.6B",
            sizeBytes: 420_000_000,
            ramBytes: 850_000_000
        ),
        Entry(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B Instruct",
            sizeBytes: 2_350_000_000,
            ramBytes: 3_200_000_000
        ),
        Entry(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            sizeBytes: 4_600_000_000,
            ramBytes: 5_500_000_000
        ),
        Entry(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 7B",
            sizeBytes: 4_060_000_000,
            ramBytes: 5_000_000_000
        ),
    ]

    public static func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
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