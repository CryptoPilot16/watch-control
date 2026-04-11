import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var watchSession = WatchSessionManager.shared
    @StateObject private var bridge = WatchBridgeClient.shared

    @State private var code = ""
    @State private var ipAddress = UserDefaults.standard.string(forKey: "bridge_host") ?? "100.78.114.85"
    @State private var isConnecting = false
    @State private var error: String?
    @State private var bridgeURL: URL?
    @State private var showDirectPairing = false
    @FocusState private var codeFocused: Bool
    @FocusState private var ipFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                relayWaitingPanel

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDirectPairing.toggle()
                    }
                } label: {
                    Text(showDirectPairing ? "Hide bridge code" : "Use bridge code")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Text.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Theme.Background.overlay)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if showDirectPairing {
                    directPairingForm
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Background.primary)
        .onAppear {
            if showDirectPairing {
                codeFocused = true
            }
        }
        .onChange(of: showDirectPairing) { _, isShowing in
            codeFocused = isShowing
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            ClaudeMascot(size: 14)
            Text("watch-control")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.Text.primary)
        }
    }

    private var relayWaitingPanel: some View {
        VStack(spacing: 6) {
            ProgressView()
                .tint(Theme.Text.primary)
                .scaleEffect(0.75)

            Text("Waiting for iPhone relay")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Text.primary)
                .multilineTextAlignment(.center)

            Text(relayInstruction)
                .font(.system(size: 10))
                .foregroundColor(Theme.Text.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(Theme.Background.overlay)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var relayInstruction: String {
        if !watchSession.isActivated {
            return "Starting the phone link..."
        }
        if watchSession.isReachable {
            return "Open watch-control on iPhone and connect to the bridge."
        }
        return "Open watch-control on iPhone. The Watch will continue once the phone connects."
    }

    private var directPairingForm: some View {
        VStack(spacing: 8) {
            Text("Pair code")
                .font(.system(size: 11))
                .foregroundColor(Theme.Text.secondary)

            TextField("000000", text: $code)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Text.primary)
                .multilineTextAlignment(.center)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                    if filtered != newValue { code = filtered }
                }

            Text("Bridge \(ipAddress)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.Text.secondary)
                .lineLimit(1)

            Button { submitCode(code) } label: {
                Text("Pair")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Theme.Text.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(ipAddress.isEmpty || code.count != 6 || isConnecting)

            if isConnecting {
                ProgressView()
                    .tint(Theme.Text.primary)
                    .scaleEffect(0.7)
            }

            TextField("Edit bridge", text: $ipAddress)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Text.primary)
                .multilineTextAlignment(.center)
                .focused($ipFocused)

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Accent.error)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func connectManual() async -> URL? {
        let bridge = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bridge.isEmpty else { return nil }
        UserDefaults.standard.set(bridge, forKey: "bridge_host")
        error = nil

        if bridge.hasPrefix("http://") || bridge.hasPrefix("https://") {
            guard let baseURL = URL(string: bridge) else { return nil }
            let statusURL = baseURL.appendingPathComponent("status")
            var request = URLRequest(url: statusURL)
            request.timeoutInterval = 3
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return baseURL
                }
            } catch {
                return nil
            }
            return nil
        }

        let ip = bridge
        for port in 7860...7869 {
            let url = URL(string: "http://\(ip):\(port)/status")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return URL(string: "http://\(ip):\(port)")
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func submitCode(_ code: String) {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil

        Task {
            do {
                guard let url = await connectManual() else {
                    throw WatchBridgeClient.BridgeError.network
                }
                await MainActor.run {
                    bridgeURL = url
                }
                try await bridge.pair(baseURL: url, code: code)
                await MainActor.run {
                    session.isPaired = true
                    session.sessionState = SessionState(
                        connection: .connected, activity: .idle,
                        machineName: "Mac", modelName: nil,
                        workingDirectory: nil,
                        elapsedSeconds: 0, filesChanged: 0, linesAdded: 0,
                        transportMode: .lan
                    )
                    session.appendLine(TerminalLine(text: "Connected to bridge", type: .system))
                    session.startEventStream()
                }
            } catch {
                await MainActor.run {
                    self.isConnecting = false
                    self.error = error.localizedDescription
                    self.code = ""
                }
            }
        }
    }
}

#Preview { OnboardingView().environmentObject(WatchViewState.shared) }
