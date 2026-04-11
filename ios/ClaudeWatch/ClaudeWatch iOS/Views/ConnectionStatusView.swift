import SwiftUI

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var showBackgroundBanner = false
    @State private var showCommandInput = false
    @State private var commandText = ""
    @State private var commandError: String?
    @State private var isSendingCommand = false
    @FocusState private var isCommandFieldFocused: Bool

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

                if let commandError {
                    Text(commandError)
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
        }
        .presentationDetents([.medium, .large])
    }

    private func sendCommandFromSheet() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isSendingCommand else { return }

        commandError = nil
        isSendingCommand = true

        Task {
            do {
                try await relayService.sendCommand(command)
                commandText = ""
                showCommandInput = false
            } catch {
                commandError = error.localizedDescription
            }
            isSendingCommand = false
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.subtleText)
                Spacer()
                Text("\(relayService.recentTerminalLines.count) lines")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.subtleText.opacity(0.6))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(relayService.recentTerminalLines) { line in
                            terminalLineView(line)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: relayService.recentTerminalLines.count) { _, _ in
                    if let lastLine = relayService.recentTerminalLines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func terminalLineView(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(colorForLineType(line.type))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorForLineType(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Color.claudeOrange
        case .command:  return .white
        case .system:   return Color.subtleText
        case .thinking: return Color.claudeOrange.opacity(0.5)
        case .error:    return .red
        }
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
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
