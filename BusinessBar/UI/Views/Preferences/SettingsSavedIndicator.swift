import Combine
import SwiftUI

// MARK: - SettingsSavedBus

/// Signals that a setting stored outside UserDefaults (Keychain, disk)
/// was written, where `UserDefaults.didChangeNotification` cannot fire.
/// Nonisolated: setters that write are not MainActor, and the receiving
/// indicator runs on Main.
enum SettingsSavedBus {
    private static let subject = PassthroughSubject<Void, Never>()

    static var publisher: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    static func announce() {
        subject.send()
    }
}

// MARK: - SettingsSavedIndicator

/// Small "Saved" flash shown after any preference write. UserDefaults
/// writes are detected through its change notification; Keychain and
/// disk writes call `SettingsSavedBus.announce()` explicitly.
struct SettingsSavedIndicator: View {
    @State private var isSavedVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isSavedVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isSavedVisible)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            flash()
        }
        .onReceive(SettingsSavedBus.publisher) { _ in
            flash()
        }
        .accessibilityLabel("Settings saved")
    }

    private func flash() {
        hideTask?.cancel()
        withAnimation { isSavedVisible = true }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { isSavedVisible = false }
        }
    }
}

// MARK: - SettingsSavedHost

/// Preferences chrome: content below, "Saved" indicator pinned to the
/// bottom-trailing corner of the window, outside the scrolling form.
struct SettingsSavedHost<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content

            SettingsSavedIndicator()
                .padding(.trailing, 20)
                .padding(.bottom, 12)
                // Lets clicks pass through to the controls underneath.
                .allowsHitTesting(false)
        }
    }
}
