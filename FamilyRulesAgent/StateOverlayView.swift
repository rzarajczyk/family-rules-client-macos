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
        VStack(spacing: 22) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)

            Text("App Restricted")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(restrictedAppPresentation.appName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.96))

            Text("This app is blocked by FamilyRules. Minimize its windows to continue using this Mac.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: 520)

            if let onMinimizeAllWindows {
                Button("Minimize all windows", action: onMinimizeAllWindows)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(Color(red: 0.55, green: 0.08, blue: 0.15))
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.40, green: 0.08, blue: 0.14), Color(red: 0.85, green: 0.29, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var lockScreenView: some View {
        VStack(spacing: 28) {
            if let icon = AppIconImage.load() {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            }

            Text("This Mac is locked")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("FamilyRules has temporarily locked this device. Ask a parent to unlock it to continue.")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: 760)
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
}
