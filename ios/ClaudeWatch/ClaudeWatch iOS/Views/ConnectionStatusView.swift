import SwiftUI
import Speech
import AVFoundation
import UIKit

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speechService = MobileSpeechService()

    @State private var showSettings = false
    @State private var showBackgroundBanner = false
    @State private var showCommandInput = false
    @State private var commandText = ""
    @State private var commandError: String?
    @State private var isSendingCommand = false
    @FocusState private var isCommandFieldFocused: Bool

    private struct TerminalTheme {
        let containerBackground: Color
        let border: Color
        let commandChevron: Color
        let commandText: Color
        let outputBullet: Color
        let outputText: Color
        let systemText: Color
        let thinkingText: Color
        let commandBarBackground: Color
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    header

                    if relayService.pendingPermission != nil {
                        permissionPrompt
                    }

                    statusCard
                    commandButton
                    terminalOutput
                    Spacer()
                    if showBackgroundBanner {
                        backgroundBanner
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(relayService)
            }
            .sheet(isPresented: $showCommandInput) {
                commandInputSheet
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            withAnimation(.easeInOut(duration: 0.3)) {
                showBackgroundBanner = (newPhase == .inactive)
            }
            // When iOS suspends the app, the SSE URLSession can be silently
            // killed without firing didCompleteWithError until much later.
            // Force a fresh stream as soon as the app returns to the
            // foreground so the terminal panel keeps receiving events
            // instead of going stale.
            if newPhase == .active {
                relayService.reconnectStream()
                relayService.syncWatchState()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeMascot(size: 32)

            Text("watch-control")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 6, height: 6)
            Text("LAN")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.statusGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.connectedPillBackground)
        .clipShape(Capsule())
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected to \(relayService.machineName ?? "Mac")")
                .font(.system(size: 15))
                .foregroundStyle(Color.claudeOrange)

            if let model = relayService.modelName {
                Label {
                    Text(model)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.subtleText)
                        .font(.system(size: 11))
                }
            }

            if let dir = relayService.workingDirectory {
                Label {
                    Text(dir)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.subtleText)
                        .font(.system(size: 11))
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.subtleText)
                    .font(.system(size: 11))
                Text(formattedElapsedTime)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
            }

            if !relayService.terminalTargets.isEmpty {
                targetPicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var targetPicker: some View {
        Menu {
            ForEach(relayService.terminalTargets) { target in
                Button {
                    relayService.selectTerminalPage(target.id)
                } label: {
                    Label(targetMenuLabel(target), systemImage: target.id == relayService.selectedTerminalTarget ? "checkmark" : "terminal")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeTargetColor)
                    .frame(width: 10, height: 10)
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                Text(activeTargetLabel)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.subtleText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(activeTargetColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Command input

    private var commandButton: some View {
        Button {
            commandError = nil
            showCommandInput = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text("Command")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("type or speak")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.claudeOrange)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!canSendCommand)
        .opacity(canSendCommand ? 1 : 0.5)
    }

    private var commandInputSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tell Claude what to do")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Say it or type it", text: $commandText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .focused($isCommandFieldFocused)
                        .submitLabel(.send)
                        .onSubmit {
                            sendCommandFromSheet()
                        }

                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: speechService.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(speechService.isRecording ? Color.red : Color.claudeOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speechService.isRecording ? "Stop dictation" : "Start dictation")

                    Button {
                        pasteCommandFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.fieldBorder)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Paste command")
                }

                Text(speechService.isRecording ? "Listening..." : "Tap the mic to speak")
                    .font(.system(size: 12))
                    .foregroundStyle(speechService.isRecording ? Color.claudeAmber : Color.subtleText)

                if let errorText = commandError ?? speechService.error {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                Button {
                    sendCommandFromSheet()
                } label: {
                    Text(isSendingCommand ? "Sending..." : "Send")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.statusGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingCommand)

                Spacer()
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        showCommandInput = false
                    }
                    .foregroundStyle(Color.subtleText)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isCommandFieldFocused = true
                }
            }
            .onChange(of: speechService.transcript) { _, transcript in
                commandText = transcript
            }
            .onDisappear {
                speechService.stopRecording()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendCommandFromSheet() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isSendingCommand else { return }

        commandError = nil
        isSendingCommand = true
        speechService.stopRecording()

        Task {
            do {
                try await relayService.sendCommand(command, target: relayService.selectedTerminalTarget)
                commandText = ""
                showCommandInput = false
            } catch {
                commandError = error.localizedDescription
            }
            isSendingCommand = false
        }
    }

    private func toggleRecording() {
        commandError = nil
        isCommandFieldFocused = false
        speechService.toggleRecording()
    }

    private func pasteCommandFromClipboard() {
        commandError = nil
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            commandError = "Clipboard is empty"
            return
        }
        commandText = text
    }

    private var canSendCommand: Bool {
        guard relayService.isPaired else { return false }
        if case .connected = relayService.connectionState {
            return true
        }
        return false
    }

    // MARK: - Permission prompt

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let permission = relayService.pendingPermission {
                // Compact header + description in one line
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.claudeAmber)
                        .font(.system(size: 14))
                    Text(permission.description)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }

                // All 3 options in a row, matching terminal UI
                HStack(spacing: 8) {
                    Button {
                        relayService.respondToPermission(permissionId: permission.id, allow: true)
                    } label: {
                        Text("Yes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.statusGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        relayService.respondToPermissionAllowAll(permissionId: permission.id)
                    } label: {
                        Text("Yes, all")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.claudeOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        relayService.respondToPermission(permissionId: permission.id, allow: false)
                    } label: {
                        Text("No")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.red.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "1a1a1a"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.claudeAmber.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Terminal output

    private var terminalOutput: some View {
        let theme = currentTerminalTheme
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                Spacer()
                Text("\(relayService.recentTerminalLines.count) lines")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.subtleText.opacity(0.6))
            }

            TabView(selection: terminalPageSelection) {
                ForEach(terminalPages) { page in
                    terminalPageView(page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: terminalPages.count > 1 ? .always : .never))
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .background(theme.containerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
    }

    private func terminalPageView(_ page: TerminalPage) -> some View {
        let theme = theme(forPageId: page.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines(for: page.id)) { line in
                        terminalLineView(line, theme: theme)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, terminalPages.count > 1 ? 18 : 0)
            }
            .onChange(of: relayService.recentTerminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollToBottom(proxy, pageId: page.id)
                }
            }
            .onChange(of: relayService.selectedTerminalTarget) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
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

    @ViewBuilder
    private func terminalLineView(_ line: TerminalLine, theme: TerminalTheme) -> some View {
        let displayType = displayType(for: line)
        switch displayType {
        case .command:
            HStack(spacing: 6) {
                Text("›")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.commandChevron)
                Text(line.text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(colorForLineType(displayType, theme: theme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(theme.commandBarBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))

        case .output:
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.outputBullet)
                Text(line.text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(colorForLineType(displayType, theme: theme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        default:
            Text(line.text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(colorForLineType(displayType, theme: theme))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, pageId: String) {
        if let lastLine = lines(for: pageId).last {
            proxy.scrollTo(lastLine.id, anchor: .bottom)
        }
    }

    private func displayType(for line: TerminalLine) -> TerminalLine.LineType {
        if line.type == .output && looksLikePromptLine(line.text) {
            return .command
        }
        return line.type
    }

    private func looksLikePromptLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") {
            return true
        }
        if trimmed.hasPrefix("/") && trimmed.count > 1 {
            return true
        }
        return false
    }

    private func colorForLineType(_ type: TerminalLine.LineType, theme: TerminalTheme) -> Color {
        switch type {
        case .output:   return theme.outputText
        case .command:  return theme.commandText
        case .system:   return theme.systemText
        case .thinking: return theme.thinkingText
        case .error:    return .red
        }
    }

    private var currentTerminalTheme: TerminalTheme {
        theme(forPageId: terminalPageSelection.wrappedValue)
    }

    private func theme(forPageId pageId: String) -> TerminalTheme {
        let pageTitle = terminalPages.first(where: { $0.id == pageId })?.title
            ?? activeTargetLabel
        let normalized = pageTitle.lowercased()
        if normalized.contains("codex") {
            return codexTerminalTheme
        }
        return claudeTerminalTheme
    }

    private var codexTerminalTheme: TerminalTheme {
        TerminalTheme(
            containerBackground: Color(hex: "0f1115"),
            border: Color.subtleText.opacity(0.55),
            commandChevron: Color(hex: "cfd2d6"),
            commandText: Color(hex: "e3e5e8"),
            outputBullet: Color(hex: "d3d6da"),
            outputText: Color(hex: "d3d6da"),
            systemText: Color.subtleText,
            thinkingText: Color(hex: "c4c7cc").opacity(0.6),
            commandBarBackground: Color(hex: "33353a")
        )
    }

    private var claudeTerminalTheme: TerminalTheme {
        TerminalTheme(
            containerBackground: Color(hex: "0f1115"),
            border: Color.claudeOrange.opacity(0.5),
            commandChevron: Color.claudeOrange,
            commandText: .white,
            outputBullet: .white,
            outputText: .white,
            systemText: Color(hex: "8f8f8f"),
            thinkingText: Color.white.opacity(0.6),
            commandBarBackground: Color(hex: "3a3b40")
        )
    }

    // MARK: - Background banner

    private var backgroundBanner: some View {
        Text("Keep this app open for real-time relay to your Watch")
            .font(.system(size: 13))
            .foregroundStyle(Color.claudeAmber)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Helpers

    private var formattedElapsedTime: String {
        let total = relayService.elapsedSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var activeTargetLabel: String {
        if let selected = selectedTarget {
            return targetMenuLabel(selected)
        }
        if let target = relayService.activeTerminalTarget {
            return target
        }
        return "No session"
    }

    private var activeTargetColor: Color {
        if let selected = selectedTarget {
            return Color(hex: selected.color)
        }
        return Color.subtleText
    }

    private var selectedTarget: BridgeTarget? {
        if let selected = relayService.selectedTerminalTarget,
           let target = relayService.terminalTargets.first(where: { $0.id == selected }) {
            return target
        }
        return relayService.terminalTargets.first(where: { $0.active })
    }

    private var terminalPages: [TerminalPage] {
        let pages = relayService.terminalTargets.map { target in
            TerminalPage(
                id: target.id,
                title: targetMenuLabel(target),
                color: target.color,
                active: target.active
            )
        }
        if !pages.isEmpty { return pages }
        return [TerminalPage(id: relayService.selectedTerminalTarget ?? "terminal", title: "Terminal", color: "666666", active: true)]
    }

    private var terminalPageSelection: Binding<String> {
        Binding(
            get: {
                relayService.selectedTerminalTarget ?? terminalPages.first?.id ?? "terminal"
            },
            set: { targetId in
                relayService.selectTerminalPage(targetId)
            }
        )
    }

    private func lines(for targetId: String) -> [TerminalLine] {
        relayService.terminalLines(for: targetId)
    }

    private func targetMenuLabel(_ target: BridgeTarget) -> String {
        let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return "\(target.id) \(target.command)"
        }
        return "\(target.id) \(title)"
    }
}

// MARK: - Mobile speech

@MainActor
private final class MobileSpeechService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startRecording() }
        }
    }

    func stopRecording() {
        guard isRecording || recognitionTask != nil || recognitionRequest != nil else { return }
        isRecording = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRecording() async {
        guard !isRecording else { return }
        error = nil

        guard await requestSpeechPermission() else {
            error = "Speech recognition permission is needed."
            return
        }

        guard await requestMicrophonePermission() else {
            error = "Microphone permission is needed."
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available right now."
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            if hasInstalledTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }
            hasInstalledTap = true

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if let recognitionError {
                        if self.isRecording {
                            self.error = recognitionError.localizedDescription
                        }
                        self.stopRecording()
                    } else if result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stopRecording()
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
