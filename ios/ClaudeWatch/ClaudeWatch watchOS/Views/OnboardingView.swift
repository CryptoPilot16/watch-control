import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var bridge = WatchBridgeClient.shared

    @State private var code = ""
    @State private var ipAddress = ""
    @State private var isConnecting = false
    @State private var error: String?
    @State private var bridgeURL: URL?
    @FocusState private var codeFocused: Bool
    @FocusState private var ipFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ClaudeMascot(size: 14)
                    Text("watch-control")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.Text.primary)
                }

                if bridgeURL != nil {
                    Text("Pair code")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Text.secondary)

                    TextField("000000", text: $code)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Text.primary)
                        .multilineTextAlignment(.center)
                        .textContentType(.oneTimeCode)
                        .focused($codeFocused)
                        .onChange(of: code) { _, newValue in
                            let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                            if filtered != newValue { code = filtered }
                            if filtered.count == 6 { submitCode(filtered) }
                        }

                    if isConnecting {
                        ProgressView()
                            .tint(Theme.Text.primary)
                            .scaleEffect(0.7)
                    }

                } else {
                    Text("Bridge IP")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Text.secondary)

                    TextField("100.x.x.x", text: $ipAddress)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Text.primary)
                        .multilineTextAlignment(.center)
                        .focused($ipFocused)

                    Button { connectManual() } label: {
                        Text("Next")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Theme.Text.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(ipAddress.isEmpty)
                }

                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Accent.error)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Background.primary)
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "bridge_host"), !saved.isEmpty {
                ipAddress = saved
            }
        }
    }

    private func connectManual() {
        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        UserDefaults.standard.set(ip, forKey: "bridge_host")
        error = nil

        Task {
            for port in 7860...7869 {
                let url = URL(string: "http://\(ip):\(port)/status")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        await MainActor.run {
                            bridgeURL = URL(string: "http://\(ip):\(port)")
                            codeFocused = true
                        }
                        return
                    }
                } catch { continue }
            }
            await MainActor.run {
                self.error = "Can't reach \(ip)"
            }
        }
    }

    private func submitCode(_ code: String) {
        guard let url = bridgeURL, !isConnecting else { return }
        isConnecting = true
        error = nil

        Task {
            do {
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
