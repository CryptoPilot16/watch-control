import Foundation
import Combine
import Speech
import UIKit

/// Coordinates communication between the bridge server, SSE event stream,
/// and the Apple Watch via WCSession.
///
/// Acts as the central hub: bridge events are received via SSE/polling,
/// parsed, and forwarded to the watch. Commands from the watch are
/// received via WCSession and forwarded to the bridge via HTTP.
@MainActor
final class RelayService: ObservableObject {

    // MARK: - Singleton

    static let shared = RelayService()

    // MARK: - Published state

    @Published private(set) var isPaired: Bool = false
    @Published private(set) var machineName: String?
    @Published private(set) var modelName: String?
    @Published private(set) var workingDirectory: String?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var recentTerminalLines: [TerminalLine] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastConnected: Date?
    @Published private(set) var terminalTargets: [BridgeTarget] = []
    @Published private(set) var activeTerminalTarget: String?
    @Published var selectedTerminalTarget: String?

    // Permission prompt state
    @Published var pendingPermission: PendingPermission? = nil

    struct PendingPermission: Identifiable {
        let id: String // permissionId from bridge
        let toolName: String
        let description: String
        let filePath: String?
        let timestamp: Date = Date()
    }

    // MARK: - Private

    private let bridgeClient = BridgeClient()
    private let sseClient = SSEClient()
    private let discovery = BonjourDiscovery()
    private let notificationService = NotificationService()
    private let sessionManager = WatchSessionManager.shared

    private let terminalBuffer = OutputRingBuffer<TerminalLine>(capacity: 50)
    private var terminalBatchTimer: Timer?
    private var pendingTerminalLines: [TerminalLine] = []
    private var watchAudioRecognitionTask: SFSpeechRecognitionTask?

    private var elapsedTimer: Timer?
    private var targetRefreshTimer: Timer?
    private var sessionStartDate: Date?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        isPaired = bridgeClient.isPaired
        setupWatchMessageHandler()
        setupSSEEventHandler()

        if isPaired {
            Task { await reconnect() }
        }
    }

    // MARK: - Pairing

    /// Discovers the bridge on LAN and pairs with the given code.
    func pair(code: String) async throws {
        print("[RelayService] Starting pair with code: \(code)")

        // Discover bridge via Bonjour (or localhost fallback)
        let service: BonjourDiscovery.DiscoveredService
        do {
            service = try await discovery.discover()
            print("[RelayService] Discovered bridge at \(service.host):\(service.port)")
        } catch {
            print("[RelayService] Discovery failed: \(error)")
            throw error
        }

        // Configure the HTTP client
        bridgeClient.configure(host: service.host, port: service.port)

        // Attempt pairing
        do {
            try await bridgeClient.pair(code: code)
            print("[RelayService] Pairing successful!")
        } catch {
            print("[RelayService] Pairing failed: \(error)")
            throw error
        }

        // Success
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        print("[RelayService] isPaired = true, starting event stream")

        await refreshTargets()

        // Start SSE connection
        startEventStream()
        startElapsedTimer()
        startTargetRefreshTimer()

        // Notify watch of connection
        updateWatchState()
    }

    /// Removes pairing and disconnects.
    func unpair() {
        sseClient.disconnect()
        bridgeClient.clearCredentials()
        stopElapsedTimer()
        stopTargetRefreshTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        machineName = nil
        modelName = nil
        workingDirectory = nil
        elapsedSeconds = 0
        recentTerminalLines = []
        connectionState = .disconnected
        terminalTargets = []
        activeTerminalTarget = nil
        selectedTerminalTarget = nil

        UserDefaults.standard.removeObject(forKey: "paired_machine_name")
        UserDefaults.standard.removeObject(forKey: "last_connected")

        // Notify watch
        let state = SessionState.disconnected
        sessionManager.updateApplicationContext(with: state)
    }

    // MARK: - Reconnection

    private func reconnect() async {
        guard bridgeClient.isPaired else { return }

        machineName = UserDefaults.standard.string(forKey: "paired_machine_name")
        if let ts = UserDefaults.standard.object(forKey: "last_connected") as? TimeInterval {
            lastConnected = Date(timeIntervalSince1970: ts)
        }

        connectionState = .connecting
        startEventStream()
        startElapsedTimer()
        startTargetRefreshTimer()
    }

    // MARK: - SSE

    private func startEventStream() {
        guard let baseURL = bridgeClient.baseURL, let token = bridgeClient.token else { return }
        sseClient.connect(baseURL: baseURL, token: token)
    }

    private func setupSSEEventHandler() {
        sseClient.onUnauthorized = { [weak self] in
            Task { @MainActor in
                self?.unpair()
            }
        }

        sseClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBridgeEvent(event)
            }
        }

        sseClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.connectionState = .connected
                    self?.lastConnected = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")
                    self?.updateWatchState()
                    self?.startTargetRefreshTimer()
                    Task { await self?.refreshTargets() }
                case .connecting:
                    self?.connectionState = .connecting
                case .disconnected:
                    self?.connectionState = .disconnected
                    self?.updateWatchState()
                }
            }
        }
    }

    /// Force the SSE stream to reconnect. Called from the foreground transition
    /// in `ConnectionStatusView` so the terminal panel recovers immediately
    /// when the app comes back from being suspended by iOS.
    func reconnectStream() {
        guard isPaired else { return }
        sseClient.reconnectNow()
    }

    /// Re-sends the latest session state to the Apple Watch. Useful when the
    /// watch app launches after the iPhone has already paired with the bridge.
    func syncWatchState() {
        guard isPaired else { return }
        sendBridgeCredentialsToWatch()
        updateWatchState()
        sendTerminalSnapshotToWatch()
        Task { await refreshTargets() }
    }

    func refreshTargets() async {
        guard isPaired else { return }
        do {
            var response = try await bridgeClient.fetchTargets()
            let allTargets = response.targets.map(\.id)
            let mirroredTargets = response.targets
                .filter { $0.mirrored == true }
                .map(\.id)
            if !allTargets.isEmpty && Set(mirroredTargets) != Set(allTargets) {
                try? await bridgeClient.selectMirrorTargets(allTargets)
                response = try await bridgeClient.fetchTargets()
            }

            terminalTargets = response.targets
            activeTerminalTarget = response.activeTarget
            let validIds = Set(response.targets.map(\.id))
            if selectedTerminalTarget == nil || !validIds.contains(selectedTerminalTarget ?? "") {
                selectedTerminalTarget = response.activeTarget ?? response.targets.first?.id
            }
            refreshRecentTerminalLines()
            updateWatchState()
        } catch {
            print("[RelayService] Failed to refresh targets: \(error)")
        }
    }

    func selectTarget(_ target: BridgeTarget) {
        Task {
            do {
                try await bridgeClient.selectTarget(target.id)
                await refreshTargets()
                let line = TerminalLine(text: "Switched to \(targetLabel(target))", type: .system)
                terminalBuffer.append(line)
                refreshRecentTerminalLines()
                pendingTerminalLines.append(line)
                scheduleBatchSend()
                reconnectStream()
            } catch {
                let line = TerminalLine(text: "Target switch failed: \(error.localizedDescription)", type: .error)
                terminalBuffer.append(line)
                refreshRecentTerminalLines()
            }
        }
    }

    func selectTerminalPage(_ targetId: String) {
        guard selectedTerminalTarget != targetId else { return }
        selectedTerminalTarget = targetId
        refreshRecentTerminalLines()

        guard let target = terminalTargets.first(where: { $0.id == targetId }) else { return }
        Task {
            try? await bridgeClient.selectTarget(target.id)
            await refreshTargets()
        }
    }

    func terminalLines(for targetId: String, limit: Int = 15) -> [TerminalLine] {
        let filtered = terminalBuffer.getAll().filter { line in
            line.targetId == nil || line.targetId == targetId
        }
        guard limit < filtered.count else { return filtered }
        return Array(filtered.suffix(limit))
    }

    private func handleBridgeEvent(_ event: SSEClient.SSEEvent) {
        guard let eventType = event.event else { return }
        let data = event.data

        switch eventType {
        case "pty-output":
            handlePtyOutput(data)

        case "permission-request":
            handlePermissionRequest(data)

        case "permission-resolved":
            handlePermissionResolved(data)

        case "session":
            handleSessionEvent(data)

        case "tool-output":
            handleToolOutput(data)

        case "task-complete":
            handleTaskComplete(data)

        case "error":
            handleError(data)

        case "stop":
            handleStop(data)

        case "poll-status":
            // Polling fallback -- just keep alive
            break

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handlePtyOutput(_ data: String) {
        guard let json = parseJSON(data),
              let text = json["text"] as? String else { return }
        let target = json["target"] as? String
        let colorHex = colorForTarget(target)

        // Strip ANSI escape codes for display
        let cleaned = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { TerminalLine(text: $0, type: .output, colorHex: colorHex, targetId: target) }
        guard !lines.isEmpty else { return }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
        }
        refreshRecentTerminalLines()

        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]

        // Build a human-readable description
        var description = ""
        var filePath: String? = nil

        switch toolName {
        case "Edit":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Edit \(filename)"
        case "Write":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Create/overwrite \(filename)"
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            description = "Run: \(String(cmd.prefix(100)))"
        case "Read":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Read \(filename)"
        default:
            description = toolName
        }

        print("[RelayService] Permission requested: \(toolName) — \(description)")

        // Show interactive prompt in the app
        pendingPermission = PendingPermission(
            id: permissionId,
            toolName: toolName,
            description: description,
            filePath: filePath
        )

        // Add to terminal as well
        let line = TerminalLine(text: "⚠ Permission: \(description)", type: .system)
        terminalBuffer.append(line)
        refreshRecentTerminalLines()

        // Forward to watch. The watch response uses ApprovalRequest.id, so keep
        // a local mapping back to the bridge's permissionId.
        let request = ApprovalRequest(
            toolName: toolName,
            actionSummary: description,
            options: [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        )
        UserDefaults.standard.set(permissionId, forKey: "pending_permission_\(request.id.uuidString)")
        let message = WatchMessage.approvalRequestMessage(request)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: description)
    }

    private func handlePermissionResolved(_ data: String) {
        guard let json = parseJSON(data),
              let permissionId = json["permissionId"] as? String else { return }

        guard pendingPermission?.id == permissionId else { return }

        let decision = json["decision"] as? [String: Any]
        let behavior = decision?["behavior"] as? String ?? "deny"
        let approved = behavior == "allow"
        let line = TerminalLine(
            text: approved ? "✓ Approved from watch" : "✗ Denied from watch",
            type: approved ? .output : .error
        )
        terminalBuffer.append(line)
        refreshRecentTerminalLines()
        pendingPermission = nil
    }

    // MARK: - Permission response

    /// "Yes, allow all" — allow this and add a permission rule so it doesn't ask again this session
    func respondToPermissionAllowAll(permissionId: String) {
        print("[RelayService] Responding to permission \(permissionId): allow (all session)")

        Task {
            do {
                try await bridgeClient.respondToApprovalAllowAll(requestId: permissionId)
                await MainActor.run {
                    let line = TerminalLine(text: "✓ Approved (all session)", type: .output)
                    self.terminalBuffer.append(line)
                    self.refreshRecentTerminalLines()
                    self.pendingPermission = nil
                }
            } catch {
                print("[RelayService] Failed to respond to permission: \(error)")
            }
        }
    }

    func respondToPermission(permissionId: String, allow: Bool) {
        print("[RelayService] Responding to permission \(permissionId): \(allow ? "allow" : "deny")")

        let decision: [String: Any] = [
            "behavior": allow ? "allow" : "deny"
        ]

        Task {
            do {
                try await bridgeClient.respondToApproval(requestId: permissionId, allow: allow)
                await MainActor.run {
                    let line = TerminalLine(
                        text: allow ? "✓ Approved" : "✗ Denied",
                        type: allow ? .output : .error
                    )
                    self.terminalBuffer.append(line)
                    self.refreshRecentTerminalLines()
                    self.pendingPermission = nil
                }
            } catch {
                print("[RelayService] Failed to respond to permission: \(error)")
            }
        }
    }

    // MARK: - Commands

    func sendCommand(_ text: String, target: String? = nil) async throws {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        do {
            try await bridgeClient.sendCommand(text: command + "\n", target: target)
        } catch {
            let message = error.localizedDescription
            terminalBuffer.append(TerminalLine(text: "Command failed: \(message)", type: .error))
            refreshRecentTerminalLines()
            throw error
        }
    }

    private func handleSessionEvent(_ data: String) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        switch state {
        case "running":
            sessionStartDate = Date()
        case "ended":
            stopElapsedTimer()
            notificationService.postTaskComplete()
        case "connected":
            connectionState = .connected
        default:
            break
        }

        updateWatchState()
    }

    private func handleToolOutput(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let toolOutput = json["tool_output"] as? String

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "$ \(cmd)", type: .command))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Show first ~10 lines of output
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "Read \(filename)", type: .system))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "Write \(filename)", type: .system))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "Edit \(filename)", type: .system))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "grep \"\(pattern)\"", type: .command))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "find \"\(pattern)\"", type: .command))

        default:
            lines.append(TerminalLine(text: "[\(toolName)]", type: .system))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
        }
        refreshRecentTerminalLines(limit: 10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
        let line = TerminalLine(text: "Task completed", type: .system)
        terminalBuffer.append(line)
        refreshRecentTerminalLines()
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error)
        terminalBuffer.append(line)
        refreshRecentTerminalLines()
    }

    private func handleStop(_ data: String) {
        let line = TerminalLine(text: "Session stopped", type: .system)
        terminalBuffer.append(line)
        refreshRecentTerminalLines()
        updateWatchState()
    }

    // MARK: - Watch communication

    private func setupWatchMessageHandler() {
        sessionManager.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
    }

    private func handleWatchMessage(_ message: WatchMessage) {
        switch message {
        case .voiceCommand(let cmd):
            // Forward voice command to bridge as PTY input
            Task {
                do {
                    try await sendCommand(cmd.transcribedText, target: cmd.targetId)
                    sendCommandStatus("Sent", targetId: cmd.targetId)
                } catch {
                    sendCommandStatus("Send failed: \(error.localizedDescription)", isError: true, targetId: cmd.targetId)
                }
            }

        case .voiceAudioCommand(let cmd):
            Task {
                await handleWatchAudioCommand(cmd)
            }

        case .pasteRequest:
            sendPasteResponseToWatch()

        case .pasteResponse, .commandStatus:
            break

        case .approvalResponse(let response):
            // Forward approval response to bridge
            let key = "pending_permission_\(response.requestId.uuidString)"
            if let permissionId = UserDefaults.standard.string(forKey: key) {
                Task {
                    try? await bridgeClient.respondToApproval(
                        requestId: permissionId,
                        allow: response.approved
                    )
                }
                UserDefaults.standard.removeObject(forKey: key)
            }

        default:
            break
        }
    }

    private func handleWatchAudioCommand(_ command: WatchMessage.VoiceAudioCommand) async {
        do {
            let text = try await transcribeWatchAudio(command.audioData)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                appendLocalLine(TerminalLine(text: "Watch voice was empty", type: .system, targetId: command.targetId))
                return
            }

            sendCommandStatus("Heard: \(text)", targetId: command.targetId)
            try await sendCommand(text, target: command.targetId)
            sendCommandStatus("Sent voice command", targetId: command.targetId)
        } catch {
            appendLocalLine(TerminalLine(text: "Watch voice failed: \(error.localizedDescription)", type: .error, targetId: command.targetId))
            sendCommandStatus("Voice failed: \(error.localizedDescription)", isError: true, targetId: command.targetId)
        }
    }

    private func transcribeWatchAudio(_ audioData: Data) async throws -> String {
        guard await requestSpeechPermission() else {
            throw BridgeClient.BridgeError.serverError("Speech recognition permission is needed.")
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw BridgeClient.BridgeError.serverError("Speech recognition is not available right now.")
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-command-\(UUID().uuidString).m4a")
        try audioData.write(to: audioURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            watchAudioRecognitionTask?.cancel()
            watchAudioRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    Task { @MainActor in self?.watchAudioRecognitionTask = nil }
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                didResume = true
                Task { @MainActor in self?.watchAudioRecognitionTask = nil }
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func appendLocalLine(_ line: TerminalLine) {
        terminalBuffer.append(line)
        pendingTerminalLines.append(line)
        refreshRecentTerminalLines()
        scheduleBatchSend()
    }

    private func sendCommandStatus(_ message: String, isError: Bool = false, targetId: String? = nil) {
        sessionManager.send(.commandStatus(WatchMessage.CommandStatus(
            message: message,
            isError: isError,
            targetId: targetId
        )))
    }

    private func sendPasteResponseToWatch() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: WatchMessage.PasteResponse
        if let text, !text.isEmpty {
            response = WatchMessage.PasteResponse(text: text)
        } else {
            response = WatchMessage.PasteResponse(error: "Clipboard is empty")
        }
        sessionManager.send(.pasteResponse(response))
    }

    private func updateWatchState() {
        let activeTarget = terminalTargets.first(where: { $0.active })
        let selectedTarget = terminalTargets.first(where: { $0.id == selectedTerminalTarget })
        let state = SessionState(
            connection: connectionState,
            activity: currentActivity,
            machineName: machineName,
            modelName: modelName,
            workingDirectory: workingDirectory,
            elapsedSeconds: elapsedSeconds,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan,
            targetId: selectedTarget?.id ?? activeTarget?.id ?? activeTerminalTarget,
            targetTitle: selectedTarget.map(targetLabel) ?? activeTarget.map(targetLabel),
            targetColor: selectedTarget?.color ?? activeTarget?.color,
            terminalPages: terminalTargets.map { target in
                TerminalPage(
                    id: target.id,
                    title: targetLabel(target),
                    color: target.color,
                    active: target.active
                )
            }
        )

        sessionManager.updateApplicationContext(with: state)
        sendBridgeCredentialsToWatch()
    }

    private func sendBridgeCredentialsToWatch() {
        guard let baseURL = bridgeClient.baseURL,
              let token = bridgeClient.token else { return }
        sessionManager.send(.bridgeCredentials(WatchMessage.BridgeCredentials(
            baseURL: baseURL.absoluteString,
            token: token
        )))
    }

    private func sendTerminalSnapshotToWatch() {
        let lines = terminalBuffer.getLast(50)
        guard !lines.isEmpty else { return }

        let update = WatchMessage.TerminalUpdate(lines: lines)
        sessionManager.send(.terminalUpdate(update))
    }

    private func refreshRecentTerminalLines(limit: Int = 15) {
        recentTerminalLines = filteredTerminalLines(limit: limit)
    }

    private func filteredTerminalLines(limit: Int) -> [TerminalLine] {
        let lines = terminalBuffer.getAll()
        let filtered = lines.filter(shouldDisplay)
        guard limit < filtered.count else { return filtered }
        return Array(filtered.suffix(limit))
    }

    private func shouldDisplay(_ line: TerminalLine) -> Bool {
        guard let targetId = line.targetId else { return true }
        return selectedTerminalTarget == nil || selectedTerminalTarget == targetId
    }

    private var currentActivity: SessionActivity {
        switch connectionState {
        case .connected: return .running
        case .connecting: return .idle
        case .disconnected: return .ended
        case .iPhoneUnreachable: return .idle
        }
    }

    private func targetLabel(_ target: BridgeTarget) -> String {
        if !target.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(target.id) \(target.title)"
        }
        return "\(target.id) \(target.command)"
    }

    private func colorForTarget(_ target: String?) -> String? {
        if let target,
           let color = terminalTargets.first(where: { $0.id == target })?.color {
            return color
        }
        return terminalTargets.first(where: { $0.active })?.color
    }

    // MARK: - Terminal batching

    private func scheduleBatchSend() {
        guard terminalBatchTimer == nil else { return }

        terminalBatchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushTerminalBatch()
            }
        }
    }

    private func flushTerminalBatch() {
        terminalBatchTimer = nil

        guard !pendingTerminalLines.isEmpty else { return }

        let lines = pendingTerminalLines
        pendingTerminalLines = []

        let update = WatchMessage.TerminalUpdate(lines: lines)
        let message = WatchMessage.terminalUpdate(update)
        sessionManager.send(message)
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        sessionStartDate = sessionStartDate ?? Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func startTargetRefreshTimer() {
        guard targetRefreshTimer == nil else { return }
        targetRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshTargets()
            }
        }
    }

    private func stopTargetRefreshTimer() {
        targetRefreshTimer?.invalidate()
        targetRefreshTimer = nil
    }

    // MARK: - JSON helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
