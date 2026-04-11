import SwiftUI
import WatchKit

struct SessionView: View {
    @EnvironmentObject private var session: WatchViewState

    @State private var commandText = ""
    @State private var commandError: String?
    @State private var isDictating = false
    @State private var cursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            // Top bar
            HStack(spacing: 4) {
                ClaudeMascot(size: 14)
                Text("Claude")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.Text.primary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            // Terminal — use regular VStack (not Lazy) to avoid blank flashes
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        // Only show last 30 lines to keep performance stable
                        ForEach(visibleLines) { line in
                            terminalLine(line)
                                .id(line.id)
                        }

                        if isThinking {
                            Text(cursorVisible ? "\u{2588}" : " ")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.Text.primary)
                                .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                                .id("cursor")
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.terminalLines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        if isThinking {
                            proxy.scrollTo("cursor", anchor: .bottom)
                        } else if let last = visibleLines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            commandBar
        }
        .background(Theme.Background.primary)
        .sheet(item: $session.pendingApproval) { request in
            ApprovalView(request: request)
        }
    }

    private var commandBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField("Type or speak", text: $commandText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(Theme.Background.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        sendCommand()
                    }

                Button {
                    startDictation()
                } label: {
                    Image(systemName: isDictating ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(isDictating ? Theme.Accent.error : Theme.Text.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isDictating)
            }

            if let commandError {
                Text(commandError)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Accent.error)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    sendCommand()
                } label: {
                    Text("Send")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Theme.Text.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // Only render last 30 lines, skip empty/thinking lines
    private var visibleLines: [TerminalLine] {
        session.terminalLines
            .filter { !$0.text.isEmpty || $0.type == .thinking }
            .suffix(30)
            .map { $0 } // convert Slice to Array
    }

    @ViewBuilder
    private func terminalLine(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(colorFor(line.type))
            .lineLimit(4)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isThinking: Bool {
        session.terminalLines.last?.type == .thinking
    }

    private func startDictation() {
        guard !isDictating else { return }
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            commandError = "Could not open dictation"
            return
        }

        commandError = nil
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
            }
        }
    }

    private func sendCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        commandError = nil
        HapticManager.commandSent()
        session.sendVoiceCommand(text)
        commandText = ""
    }

    private var statusColor: Color {
        switch session.sessionState.connection {
        case .connected: return Theme.Accent.success
        case .connecting: return Theme.Text.secondary
        case .disconnected: return Theme.Accent.error
        case .iPhoneUnreachable: return Theme.Accent.approval
        }
    }

    private func colorFor(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Theme.Text.primary
        case .command:  return .white
        case .system:   return Theme.Text.secondary
        case .thinking: return Theme.Text.primary.opacity(0.5)
        case .error:    return Theme.Accent.error
        }
    }
}

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

#Preview {
    SessionView()
        .environmentObject(WatchViewState.shared)
}
