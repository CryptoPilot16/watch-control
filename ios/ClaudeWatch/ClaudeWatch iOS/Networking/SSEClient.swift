import Foundation

/// Server-Sent Events client that connects to the bridge `/events` endpoint.
/// Supports automatic reconnection with `Last-Event-ID` and heartbeat timeout
/// detection. Reconnects indefinitely with exponential backoff (1s → 30s).
final class SSEClient {

    // MARK: - Types

    struct SSEEvent {
        let id: String?
        let event: String?
        let data: String
    }

    enum SSEState {
        case disconnected
        case connecting
        case connected
    }

    // MARK: - Configuration

    private let heartbeatTimeout: TimeInterval = 15.0
    private let initialBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0

    // MARK: - Callbacks

    var onEvent: ((SSEEvent) -> Void)?
    var onStateChange: ((SSEState) -> Void)?

    // MARK: - Properties

    private(set) var state: SSEState = .disconnected {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    private var baseURL: URL?
    private var token: String?
    private var lastEventId: String?

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var heartbeatTimer: Timer?
    private var ignoredCompletionTaskIds = Set<Int>()

    /// Current backoff delay for the next reconnect attempt. Doubles on each
    /// consecutive failure and resets to `initialBackoff` after a successful
    /// connection.
    private var currentBackoff: TimeInterval = 1.0

    // Buffer for parsing SSE lines
    private var lineBuffer = ""
    private var currentEventType: String?
    private var currentEventData: [String] = []
    private var currentEventId: String?

    // Delegate for streaming
    private var sessionDelegate: SSESessionDelegate?

    // MARK: - Lifecycle

    func connect(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        currentBackoff = initialBackoff
        startSSE()
    }

    func disconnect() {
        stopSSE()
        baseURL = nil
        token = nil
        state = .disconnected
    }

    /// Force a fresh SSE connection. Safe to call repeatedly — typically used
    /// from the foreground transition to recover from an iOS-suspended session
    /// without waiting for the heartbeat watchdog.
    func reconnectNow() {
        guard baseURL != nil, token != nil else { return }
        currentBackoff = initialBackoff
        startSSE()
    }

    // MARK: - SSE Connection

    private func startSSE() {
        stopSSE()
        state = .connecting

        guard let baseURL, let token else { return }

        let eventsURL = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: eventsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 0 // No timeout for SSE

        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        let delegate = SSESessionDelegate(client: self)
        self.sessionDelegate = delegate

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.urlSession = session

        let task = session.dataTask(with: request)
        self.dataTask = task
        task.resume()

        resetHeartbeatTimer()
    }

    private func stopSSE() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let dataTask {
            ignoredCompletionTaskIds.insert(dataTask.taskIdentifier)
            dataTask.cancel()
        }
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        lineBuffer = ""
        currentEventType = nil
        currentEventData = []
        currentEventId = nil
    }

    // MARK: - Heartbeat

    private func resetHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: heartbeatTimeout,
            repeats: false
        ) { [weak self] _ in
            self?.handleHeartbeatTimeout()
        }
    }

    private func handleHeartbeatTimeout() {
        // No data (not even a `:heartbeat` comment) within the watchdog window:
        // the connection is dead even if URLSession hasn't noticed yet.
        scheduleReconnect()
    }

    // MARK: - Reconnect with exponential backoff

    private func scheduleReconnect() {
        stopSSE()
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, maxBackoff)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.baseURL != nil, self.token != nil else { return }
            self.startSSE()
        }
    }

    // MARK: - SSE Parsing

    fileprivate func handleSSEConnected() {
        currentBackoff = initialBackoff
        DispatchQueue.main.async {
            self.state = .connected
        }
    }

    fileprivate func handleReceivedData(_ data: Data) {
        resetHeartbeatTimer()

        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text

        // Process complete lines
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            processSSELine(line)
        }
    }

    private func processSSELine(_ line: String) {
        // Empty line = end of event
        if line.isEmpty {
            dispatchCurrentEvent()
            return
        }

        // Comment (heartbeat)
        if line.hasPrefix(":") {
            return
        }

        // Parse field:value
        if line.hasPrefix("id:") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            currentEventId = value
        } else if line.hasPrefix("event:") {
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            currentEventType = value
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            currentEventData.append(value)
        } else if line.hasPrefix("retry:") {
            // Could adjust reconnection interval; ignored for now
        }
    }

    private func dispatchCurrentEvent() {
        guard !currentEventData.isEmpty else {
            // Reset but no event to dispatch
            currentEventType = nil
            currentEventId = nil
            return
        }

        let data = currentEventData.joined(separator: "\n")
        let event = SSEEvent(
            id: currentEventId,
            event: currentEventType,
            data: data
        )

        if let id = currentEventId {
            lastEventId = id
        }

        // Reset
        currentEventType = nil
        currentEventData = []
        currentEventId = nil

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    fileprivate func handleSSEError(_ error: Error?, taskIdentifier: Int) {
        if ignoredCompletionTaskIds.remove(taskIdentifier) != nil {
            return
        }
        scheduleReconnect()
    }

    fileprivate func handleSSEComplete(taskIdentifier: Int) {
        if ignoredCompletionTaskIds.remove(taskIdentifier) != nil {
            return
        }
        // Stream ended gracefully -- reconnect.
        scheduleReconnect()
    }
}

// MARK: - URLSession Delegate for streaming

private final class SSESessionDelegate: NSObject, URLSessionDataDelegate {

    private weak var client: SSEClient?

    init(client: SSEClient) {
        self.client = client
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            client?.handleSSEConnected()
            completionHandler(.allow)
        } else {
            client?.handleSSEError(nil, taskIdentifier: dataTask.taskIdentifier)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.handleReceivedData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            client?.handleSSEError(error, taskIdentifier: task.taskIdentifier)
        } else {
            client?.handleSSEComplete(taskIdentifier: task.taskIdentifier)
        }
    }
}
