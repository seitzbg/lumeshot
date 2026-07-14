import Foundation

public enum RecordingError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case startFailed(String)
    case recordingFailed(String)
    case conversionFailed(String)
}
