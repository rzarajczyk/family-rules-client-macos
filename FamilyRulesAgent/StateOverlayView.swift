import SwiftUI

struct RestrictedAppOverlayPresentation: Equatable {
    let appIdentifier: String
    let appName: String
}

struct StateOverlayView: View {
    let countdownPresentation: StateCountdownPresentation?
    let restrictedAppPresentation: RestrictedAppOverlayPresentation?
    let onMinimizeAllWindows: (() -> Void)?

    var body: some View {
        Group {
            if let countdownPresentation {
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
            } else if let restrictedAppPresentation {
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
            } else {
                Color.clear
            }
        }
    }
}
