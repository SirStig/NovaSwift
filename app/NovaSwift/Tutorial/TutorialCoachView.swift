import SwiftUI

/// The coaching overlay drawn over the training flight: a bottom card with the
/// current step's instruction, a progress row, and the controls to advance or
/// leave. Objective steps advance themselves when the goal is met; manual steps
/// wait for Continue. A "Skip Tutorial" affordance is always available.
struct TutorialCoachView: View {
    @ObservedObject var run: TutorialRun
    /// Label for the primary button on the final card ("Begin Your Journey" from
    /// the new-pilot flow, "Return to Menu" when replayed from the menu).
    var finishLabel: String
    var onFinish: () -> Void

    var body: some View {
        VStack {
            // Always-available exit, top-trailing, clear of the menu button at
            // top-leading and the status panel on the right.
            HStack {
                Spacer()
                Button {
                    onFinish()
                } label: {
                    Label("Skip Tutorial", systemImage: "xmark")
                        .novaFont(.caption, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .padding(.trailing, 14)

            Spacer()

            if let step = run.current {
                card(step)
                    .id(step.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: run.index)
    }

    @ViewBuilder
    private func card(_ step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(novaAmber)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .novaFont(.heading, weight: .bold).foregroundStyle(.white)
                    Text("Step \(run.stepNumber) of \(run.stepCount)")
                        .novaFont(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            Text(step.body)
                .novaFont(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            progressDots

            footer(step)
        }
        .padding(18)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(novaAmber.opacity(0.35)))
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(run.steps.enumerated()), id: \.element.id) { i, _ in
                Capsule()
                    .fill(i <= run.index ? novaAmber : Color.white.opacity(0.22))
                    .frame(width: i == run.index ? 16 : 7, height: 5)
                    .animation(.easeOut(duration: 0.25), value: run.index)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func footer(_ step: TutorialStep) -> some View {
        HStack {
            if step.isManual {
                Spacer()
                Button {
                    if run.isLast { onFinish() } else { run.advance() }
                } label: {
                    Text(run.isLast ? finishLabel : "Continue")
                        .novaFont(.button)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Capsule().fill(novaAmber))
                }
                .buttonStyle(.plain)
            } else {
                // Objective steps complete on their own; the hint reassures the
                // player the game is watching, and the skip is an escape hatch if
                // they get stuck on one action.
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(novaAmber)
                    Text("Try it — this advances on its own")
                        .novaFont(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { run.advance() } label: {
                    Text("Skip step ›")
                        .novaFont(.caption, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
