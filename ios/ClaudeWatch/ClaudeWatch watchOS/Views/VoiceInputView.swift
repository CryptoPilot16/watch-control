import SwiftUI
import WatchKit

// MARK: - VoiceInputView

/// Full-screen voice capture mode. Uses watchOS system dictation (TextField with dictation)
/// since the Speech framework is not available on watchOS.
struct VoiceInputView: View {
    @EnvironmentObject private var session: WatchViewState
    @Environment(\.dismiss) private var dismiss

    @State private var commandText = ""
    @State private var errorMessage: String?
    @State private var isDictating = false
    @State private var animationPhase: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool

    private let waveTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.Background.capture.ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Say your command")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Text.primary)

                // Waveform animation (decorative)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Text.primary)
                            .frame(width: 6, height: barHeight(for: index))
                    }
                }
                .frame(height: 40)
                .onReceive(waveTimer) { _ in
                    animationPhase += 1
                }

                Button {
                    startDictation()
                } label: {
                    Label(isDictating ? "Listening" : "Speak", systemImage: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.Text.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isDictating)

                TextField("Or type command", text: $commandText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        sendCommand()
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Accent.error)
                        .multilineTextAlignment(.center)
                }

                if !commandText.isEmpty {
                    // Send button
                    Button {
                        sendCommand()
                    } label: {
                        Text("Send")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.Text.primary)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Text.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            isTextFieldFocused = false
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 12
        let variation: CGFloat = 20
        let phase = animationPhase + CGFloat(index) * 2
        return base + abs(sin(phase * 0.3)) * variation
    }

    private func startDictation() {
        guard !isDictating else { return }
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            errorMessage = "Could not open dictation"
            return
        }

        errorMessage = nil
        isDictating = true
        controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        ) { results in
            DispatchQueue.main.async {
                isDictating = false

                guard let text = results?.compactMap({ $0 as? String }).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return }

                commandText = text
                sendCommand()
            }
        }
    }

    private func sendCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        HapticManager.commandSent()
        session.sendVoiceCommand(text)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    VoiceInputView()
        .environmentObject(WatchViewState.shared)
}
