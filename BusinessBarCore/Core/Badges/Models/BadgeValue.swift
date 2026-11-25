import Foundation

/// Dock badge state. Apps like Messages or Mail expose a real unread count
/// through the Dock's AXStatusLabel. Some apps only show a plain dot with no
/// number at all, in which case the honest state is unknown, not a count of 1.
/// The absence of a badge is modeled by Optional.none, so every case here
/// means "there is a badge".
public enum BadgeValue: Equatable, Hashable {
    /// The Dock label carries a real count.
    case known(Int)
    /// The Dock label is set but carries no digits: notifications exist, the
    /// number does not.
    case unknown

    /// Menu bar toast text; nil for the dot state, which has no number to show.
    public var toastText: String? {
        switch self {
        case .known(let count): return count > 99 ? "99+" : "\(count)"
        case .unknown: return nil
        }
    }
}

public extension Optional where Wrapped == BadgeValue {
    /// Encoded form for MonitoredApp's persisted JSON: a plain Int keeps the
    /// on-disk format identical to the pre-BadgeValue releases, so downgrades
    /// keep reading the file and old files decode without data loss.
    /// 0 encodes no badge, -1 encodes unknown, n > 0 encodes known(n).
    var persistedCount: Int {
        switch self {
        case .none: return 0
        case .some(.known(let count)): return max(count, 0)
        case .some(.unknown): return -1
        }
    }

    static func from(persistedCount: Int) -> BadgeValue? {
        guard persistedCount != 0 else { return nil }
        return persistedCount > 0 ? .known(persistedCount) : .unknown
    }
}
