//
//  ModePhase.swift
//  Axii
//
//  Generic phase enum for ModeFeature state machine.
//

#if os(macOS)
enum ModePhase: Equatable {
    case idle
    case preparing
    case recording
    case transcribing
    case processing
    case done
    case error(String)

    var isRecording: Bool { self == .recording }
    var isActive: Bool { self != .idle }
}
#endif
