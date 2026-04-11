import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    @State private var showForgetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                pairedBridgeSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(Color.claudeOrange)
                }
            }
            .alert("Forget Bridge?", isPresented: $showForgetConfirmation) {
                Button("Forget", role: .destructive) {
                    relayService.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You will need to re-pair using a fresh code from your bridge.")
            }
        }
    }

    // MARK: - Sections

    private var pairedBridgeSection: some View {
        Section("Paired Bridge") {
            if relayService.isPaired {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relayService.machineName ?? "Unknown bridge")
                            .foregroundStyle(.white)
                        if let lastConnected = relayService.lastConnected {
                            Text("Last connected \(lastConnected, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(Color.subtleText)
                        }
                    }
                    Spacer()
                }

                Button("Forget This Bridge", role: .destructive) {
                    showForgetConfirmation = true
                }
            } else {
                Text("No bridge paired")
                    .foregroundStyle(Color.subtleText)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    .foregroundStyle(Color.subtleText)
            }

            Link(destination: URL(string: "https://github.com/CryptoPilot16/watch-control")!) {
                HStack {
                    Text("watch-control on GitHub")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.subtleText)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(RelayService.shared)
}
