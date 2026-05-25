import BusinessBarCore
import SwiftUI

/// Consolidates visual and cosmetic settings that affect how BusinessBar
/// appears in the menu bar and across the UI.
struct AppearanceTab: View {

    // MARK: - Badge icon appearance

    @AppStorage(Constants.Defaults.badgeIconSize) private var badgeIconSize = "small"
    @AppStorage(Constants.Defaults.grayscaleWhenNoNotifications) private var grayscaleWhenNoNotifications = true

    // MARK: - Status bar text

    @AppStorage(Constants.Defaults.timeFormat) private var timeFormat = "relative"
    @AppStorage(Constants.Defaults.timeRoundingThreshold) private var timeRoundingThreshold = Constants.DefaultValues.timeRoundingThreshold
    @AppStorage(Constants.Defaults.meetingTitleMaxLength) private var titleMaxLength = Constants.DefaultValues.meetingTitleMaxLength

    var body: some View {
        Form {
            // MARK: Status Bar
            Section("Status Bar Text") {
                VStack(alignment: .leading) {
                    Text("Meeting title max length:")
                    HStack {
                        Slider(value: Binding(
                            get: { Double(titleMaxLength) },
                            set: { titleMaxLength = Int($0) }
                        ), in: 10...50, step: 1)
                        Text("\(titleMaxLength) characters")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                    }
                }

                Picker("Event time format:", selection: $timeFormat) {
                    Text("Relative (\"in 12m\" / \"now (25m left)\")").tag("relative")
                    Text("Absolute (\"10:00\")").tag("absolute")
                }
                .pickerStyle(.radioGroup)

                if timeFormat == "relative" {
                    VStack(alignment: .leading) {
                        Text("Time rounding threshold:")
                        HStack {
                            Slider(value: Binding(
                                get: { Double(timeRoundingThreshold) },
                                set: { timeRoundingThreshold = Int($0) }
                            ), in: 0...12, step: 1)
                            Text(roundingLabel)
                                .foregroundColor(.secondary)
                                .frame(width: 160, alignment: .leading)
                        }
                        Text("0 = always exact (\"1h31m\"). 1+ = round to whole hours when ≥ that many hours away.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // MARK: Badge Icons
            Section("Badge Icons") {
                Picker("Badge icon size:", selection: $badgeIconSize) {
                    Text("Small (14px)").tag("small")
                    Text("Medium (18px)").tag("medium")
                }
                .pickerStyle(.radioGroup)

                Toggle("Grayscale when no notifications", isOn: $grayscaleWhenNoNotifications)

                Text("When enabled, badge icons appear desaturated until a notification is present.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Preview
            Section("Preview") {
                appearancePreview
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }

    // MARK: - Preview

    @ViewBuilder
    private var appearancePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status bar preview")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                // Simulated meeting text
                Text(previewMeetingText)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Badge icon preview")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            HStack(spacing: 16) {
                badgePreview(count: 0, label: "No badge")
                badgePreview(count: 3, label: "3 notifications")
                badgePreview(count: 0, label: "No badge (grayscale)", forceGrayscale: true)
            }
        }
    }

    @ViewBuilder
    private func badgePreview(count: Int, label: String, forceGrayscale: Bool = false) -> some View {
        VStack(spacing: 6) {
            let size: CGFloat = badgeIconSize == "medium" ? 18 : 14

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: size + 8, height: size + 8)

                if forceGrayscale || (count == 0 && grayscaleWhenNoNotifications) {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: size, height: size)
                        .foregroundColor(.secondary)
                } else if count > 0 {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: size, height: size)
                            .foregroundColor(.accentColor)

                        Text("\(count)")
                            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: size * 0.2, y: -size * 0.2)
                    }
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: size, height: size)
                        .foregroundColor(.secondary)
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
    }

    // MARK: - Helpers

    private var roundingLabel: String {
        if timeRoundingThreshold == 0 {
            return "Always exact"
        } else {
            return "Round when ≥\(timeRoundingThreshold)h away"
        }
    }

    private var previewMeetingText: String {
        let truncated = "Team Standup".truncated(to: titleMaxLength)
        switch timeFormat {
        case "relative":
            if timeRoundingThreshold > 0 && timeRoundingThreshold <= 1 {
                return "\(truncated) in 2h  "
            } else {
                return "\(truncated) in 1h31m  "
            }
        case "absolute":
            return "\(truncated) (10:00-10:30)  "
        default:
            return "\(truncated) in 1h31m  "
        }
    }
}