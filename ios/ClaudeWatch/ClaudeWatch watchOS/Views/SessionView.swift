import SwiftUI
import AVFoundation

struct SessionView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var audioRecorder = WatchAudioRecorder()

    @State private var commandText = ""
    @State private var commandError: String?
    @State private var cursorVisible = true
    @State private var isPressingActionButton = false
    @State private var isStartingRecording = false
    @State private var longPressTask: Task<Void, Never>?
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            // Top bar
            HStack(spacing: 3) {
                ClaudeMascot(size: 11)
                Text("Claude")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(targetColor)
                if let targetId = session.selectedTerminalTarget ?? session.sessionState.targetId {
                    Text(targetId)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(targetColor)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 4, height: 4)
            }
            .padding(.horizontal, 3)

            TabView(selection: terminalPageSelection) {
                ForEach(session.terminalPages) { page in
                    terminalPage(page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: session.terminalPages.count > 1 ? .always : .never))

            commandBar
        }
        .background(Theme.Background.primary)
        .sheet(item: $session.pendingApproval) { request in
            ApprovalView(request: request)
        }
        .onChange(of: session.pastedCommandText) { _, pastedText in
            guard let pastedText else { return }
            commandText = pastedText
            session.pastedCommandText = nil
        }
        .onDisappear {
            longPressTask?.cancel()
            isPressingActionButton = false
            isStartingRecording = false
            audioRecorder.cancel()
        }
    }

    private var commandBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Circle()
                    .fill(targetColor)
                    .frame(width: 5, height: 5)
                TextField("Type or speak", text: $commandText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(targetColor)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 5)
                    .frame(height: 26)
                    .background(Theme.Background.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        sendCommand()
                    }

                actionButton
            }

            if let statusText = commandStatusText {
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundColor(commandStatusIsError ? Theme.Accent.error : Theme.Text.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 1)
    }

    private var actionButton: some View {
        Image(systemName: actionButtonIcon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.black)
            .frame(width: 26, height: 26)
            .background(actionButtonColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        beginActionPress()
                    }
                    .onEnded { _ in
                        endActionPress()
                    }
            )
    }

    private func terminalPage(_ page: TerminalPage) -> some View {
        let lines = visibleLines(for: page.id)
        let latestLineId = lines.last?.id

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        terminalLine(line, isLatest: line.id == latestLineId)
                            .id(line.id)
                    }

                    if isThinking(on: page.id) {
                        Text(cursorVisible ? "\u{2588}" : " ")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: page.color))
                            .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                            .id("cursor-\(page.id)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom-\(page.id)")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, session.terminalPages.count > 1 ? 6 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.terminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    scrollToBottom(proxy, pageId: page.id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToBottom(proxy, pageId: page.id)
                }
            }
            .onChange(of: session.selectedTerminalTarget) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    scrollToBottom(proxy, pageId: page.id)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollToBottom(proxy, pageId: page.id)
                }
            }
        }
    }

    private func visibleLines(for targetId: String) -> [TerminalLine] {
        session.terminalLines(for: targetId)
            .filter { !$0.text.isEmpty || $0.type == .thinking }
    }

    @ViewBuilder
    private func terminalLine(_ line: TerminalLine, isLatest: Bool) -> some View {
        Text(line.text)
            .font(.system(size: 11, weight: isLatest ? .bold : .regular, design: .monospaced))
            .foregroundColor(colorFor(line))
            .lineLimit(4)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, pageId: String) {
        proxy.scrollTo("bottom-\(pageId)", anchor: .bottom)
    }

    private func isThinking(on targetId: String) -> Bool {
        visibleLines(for: targetId).last?.type == .thinking
    }

    private var terminalPageSelection: Binding<String> {
        Binding(
            get: {
                session.selectedTerminalTarget ?? session.terminalPages.first?.id ?? "terminal"
            },
            set: { targetId in
                session.selectTerminalPage(targetId)
            }
        )
    }

    private var targetColor: Color {
        if let target = session.terminalPages.first(where: { $0.id == session.selectedTerminalTarget }) {
            return Color(hex: target.color)
        }
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
            return "Listening... release to send"
        }
        if isStartingRecording {
            return "Starting mic..."
        }
        return session.commandStatusText(for: terminalPageSelection.wrappedValue)
    }

    private var commandStatusIsError: Bool {
        commandError != nil || (!audioRecorder.isRecording && !isStartingRecording && session.commandStatusIsError)
    }

    private var actionButtonIcon: String {
        if audioRecorder.isRecording {
            return "stop.fill"
        }
        return canSendTypedCommand ? "paperplane.fill" : "mic.fill"
    }

    private var actionButtonColor: Color {
        if audioRecorder.isRecording {
            return Theme.Accent.error
        }
        return canSendTypedCommand ? targetColor : Theme.Text.dimmed
    }

    private var canSendTypedCommand: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginActionPress() {
        guard !isPressingActionButton else { return }
        commandError = nil
        isPressingActionButton = true
        longPressTask?.cancel()
        longPressTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isPressingActionButton, !audioRecorder.isRecording else { return }
                startRecording()
            }
        }
    }

    private func endActionPress() {
        guard isPressingActionButton else { return }
        isPressingActionButton = false
        longPressTask?.cancel()
        longPressTask = nil

        if audioRecorder.isRecording {
            stopAndSendRecording()
        } else if isStartingRecording {
            commandError = nil
        } else if canSendTypedCommand {
            sendCommand()
        } else {
            commandError = "Type text or hold to speak"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if commandError == "Type text or hold to speak" {
                    commandError = nil
                }
            }
        }
    }

    private func startRecording() {
        commandError = nil
        isStartingRecording = true
        Task {
            let started = await audioRecorder.start()
            isStartingRecording = false
            if !started {
                commandError = audioRecorder.error ?? "Could not start microphone"
            } else if !isPressingActionButton {
                stopAndSendRecording()
            }
        }
    }

    private func stopAndSendRecording() {
        guard let audioData = audioRecorder.stop() else {
            commandError = audioRecorder.error ?? "Could not capture audio"
            return
        }
        HapticManager.commandSent()
        session.sendAudioCommand(audioData)
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
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-command-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 12_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000,
                AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
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
