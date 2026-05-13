import AppKit
import SwiftUI

struct RestrictedAppOverlayPresentation: Equatable {
    let appIdentifier: String
    let appName: String
}

struct StateOverlayView: View {
    let countdownPresentation: StateCountdownPresentation?
    let restrictedAppPresentation: RestrictedAppOverlayPresentation?
    let lockScreenActive: Bool
    let compactCountdown: Bool
    let onMinimizeAllWindows: (() -> Void)?

    var body: some View {
        Group {
            if lockScreenActive || countdownPresentation != nil || restrictedAppPresentation != nil {
                ZStack {
                    if lockScreenActive {
                        lockScreenView
                    } else if let restrictedAppPresentation {
                        restrictedAppView(restrictedAppPresentation)
                    }

                    if let countdownPresentation, !lockScreenActive {
                        countdownView(countdownPresentation)
                            .zIndex(1)
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func countdownView(_ countdownPresentation: StateCountdownPresentation) -> some View {
        if compactCountdown {
            VStack(alignment: .leading, spacing: 10) {
                Text(countdownPresentation.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Text(countdownPresentation.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(countdownPresentation.secondsRemaining)s")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.13, blue: 0.58), Color(red: 0.74, green: 0.18, blue: 0.29)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)

                Text(countdownPresentation.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(countdownPresentation.message)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.92))

                Text("\(countdownPresentation.secondsRemaining)s")
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.13, blue: 0.58), Color(red: 0.74, green: 0.18, blue: 0.29)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private func restrictedAppView(_ restrictedAppPresentation: RestrictedAppOverlayPresentation) -> some View {
        lockedOverlayLayout(
            appIcon: appIcon(for: restrictedAppPresentation.appIdentifier),
            title: String(format: String.localized("%@ is blocked"), restrictedAppPresentation.appName),
            subtitle: String.localized("FamilyRules blocked this app on this Mac. Minimize its windows to continue."),
            actionTitle: onMinimizeAllWindows == nil ? nil : String.localized("Minimize all windows"),
            action: onMinimizeAllWindows
        )
    }

    private var lockScreenView: some View {
        lockedOverlayLayout(
            appIcon: AppIconImage.load(),
            title: String.localized("This Mac is locked"),
            subtitle: String.localized("FamilyRules has temporarily locked this device. Ask a parent to unlock it to continue.")
        )
    }

    private func lockedOverlayLayout(
        appIcon: NSImage? = nil,
        iconSystemName: String? = nil,
        title: String,
        subtitle: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 28) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            } else if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            }

            Text(title)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let detail {
                Text(detail)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.96))
                    .frame(maxWidth: 760)
            }

            Text(subtitle)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: 760)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color(red: 0.95, green: 0.44, blue: 0.33))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                    .padding(.top, 6)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.05, blue: 0.16), Color(red: 0.50, green: 0.07, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func appIcon(for identifier: String) -> NSImage? {
        if FileManager.default.fileExists(atPath: identifier) {
            return NSWorkspace.shared.icon(forFile: identifier)
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }
}
