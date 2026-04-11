import SwiftUI
import WatchKit
import AVFoundation

struct SessionView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var audioRecorder = WatchAudioRecorder()

    @State private var commandText = ""
    @State private var commandError: String?
    @State private var cursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            // Top bar
            HStack(spacing: 4) {
                ClaudeMascot(size: 14)
                Text("Claude")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(targetColor)
                if let targetId = session.sessionState.targetId {
                    Text(targetId)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(targetColor)
                        .lineLimit(1)
                }
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
        .onDisappear {
            audioRecorder.cancel()
        }
    }

    private var commandBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(targetColor)
                    .frame(width: 8, height: 8)
                TextField("Type or speak", text: $commandText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(targetColor)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(Theme.Background.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        sendCommand()
                    }

                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(audioRecorder.isRecording ? Theme.Accent.error : targetColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    sendCommand()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(canSendTypedCommand ? targetColor : Theme.Text.dimmed)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSendTypedCommand)
            }

            if let statusText = commandStatusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(commandError == nil ? Theme.Text.secondary : Theme.Accent.error)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
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
            .foregroundColor(colorFor(line))
            .lineLimit(4)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isThinking: Bool {
        session.terminalLines.last?.type == .thinking
    }

    private var targetColor: Color {
        if let hex = session.sessionState.targetColor {
            return Color(hex: hex)
        }
        return Theme.Text.primary
    }

    private var commandStatusText: String? {
        if let commandError {
            return commandError
        }
        if audioRecorder.isRecording {
            return "Listening... tap stop to send"
        }
        return nil
    }

    private var canSendTypedCommand: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleRecording() {
        commandError = nil
        if audioRecorder.isRecording {
            guard let audioData = audioRecorder.stop() else {
                commandError = audioRecorder.error ?? "Could not capture audio"
                return
            }
            HapticManager.commandSent()
            session.sendAudioCommand(audioData)
        } else {
            Task {
                let started = await audioRecorder.start()
                if !started {
                    commandError = audioRecorder.error ?? "Could not start microphone"
                }
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

    private func colorFor(_ line: TerminalLine) -> Color {
        if (line.type == .output || line.type == .command),
           let colorHex = line.colorHex {
            return Color(hex: colorHex)
        }

        switch line.type {
        case .output:   return Theme.Text.primary
        case .command:  return .white
        case .system:   return Theme.Text.secondary
        case .thinking: return Theme.Text.primary.opacity(0.5)
        case .error:    return Theme.Accent.error
        }
    }
}

@MainActor
private final class WatchAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var error: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start() async -> Bool {
        guard !isRecording else { return true }
        error = nil

        guard await requestMicrophonePermission() else {
            error = "Microphone permission is needed."
            return false
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-command-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                error = "Could not start recording."
                return false
            }

            self.recorder = recorder
            recordingURL = url
            isRecording = true
            return true
        } catch {
            self.error = error.localizedDescription
            cancel()
            return false
        }
    }

    func stop() -> Data? {
        guard isRecording, let recorder, let recordingURL else { return nil }
        recorder.stop()
        isRecording = false
        self.recorder = nil
        self.recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        do {
            let data = try Data(contentsOf: recordingURL)
            try? FileManager.default.removeItem(at: recordingURL)
            return data
        } catch {
            self.error = error.localizedDescription
            try? FileManager.default.removeItem(at: recordingURL)
            return nil
        }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
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
