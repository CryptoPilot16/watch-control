import Foundation

enum ConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case iPhoneUnreachable
}

enum SessionActivity: String, Codable {
    case idle
    case running
    case waitingApproval
    case ended
}

struct SessionState: Codable {
    var connection: ConnectionState
    var activity: SessionActivity
    var machineName: String?
    var modelName: String?
    var workingDirectory: String?
    var elapsedSeconds: Int
    var filesChanged: Int
    var linesAdded: Int
    var transportMode: TransportMode
    var targetId: String?
    var targetTitle: String?
    var targetColor: String?

    enum TransportMode: String, Codable {
        case lan
        case remote
    }

    init(
        connection: ConnectionState,
        activity: SessionActivity,
        machineName: String? = nil,
        modelName: String? = nil,
        workingDirectory: String? = nil,
        elapsedSeconds: Int,
        filesChanged: Int,
        linesAdded: Int,
        transportMode: TransportMode,
        targetId: String? = nil,
        targetTitle: String? = nil,
        targetColor: String? = nil
    ) {
        self.connection = connection
        self.activity = activity
        self.machineName = machineName
        self.modelName = modelName
        self.workingDirectory = workingDirectory
        self.elapsedSeconds = elapsedSeconds
        self.filesChanged = filesChanged
        self.linesAdded = linesAdded
        self.transportMode = transportMode
        self.targetId = targetId
        self.targetTitle = targetTitle
        self.targetColor = targetColor
    }

    static var disconnected: SessionState {
        SessionState(
            connection: .disconnected,
            activity: .idle,
            machineName: nil,
            modelName: nil,
            workingDirectory: nil,
            elapsedSeconds: 0,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan
        )
    }
}
