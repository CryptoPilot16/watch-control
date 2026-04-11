import Foundation

struct TerminalLine: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let type: LineType
    let colorHex: String?

    enum LineType: String, Codable {
        case output      // Claude's output
        case command     // User's command (prefixed with >)
        case system      // System messages (connected, disconnected, etc.)
        case thinking    // Pulsing cursor indicator
        case error       // Error messages
    }

    init(text: String, type: LineType = .output, colorHex: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.type = type
        self.colorHex = colorHex
    }
}
