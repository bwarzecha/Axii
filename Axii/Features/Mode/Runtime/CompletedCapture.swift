//
//  CompletedCapture.swift
//  Axii
//
//  Value object representing a completed audio capture, ready for
//  post-capture processing. This is the seam between capture lifecycle
//  (owned by ModeFeature/ModeFeatureRecording) and turn execution
//  (owned by the mode-family-specific processor).
//

#if os(macOS)

struct CompletedCapture {
    let samples: [Float]
    let sampleRate: Double
    let focusSnapshot: FocusSnapshot?
}

#endif
