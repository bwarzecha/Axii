//
//  PipelineContext.swift
//  Axii
//
//  Shared data bag that flows through processing pipeline steps.
//
//  - `text`: The "traveling text" — starts as the transcription, updated
//    by each text-producing step. Outputs use this by default.
//  - `results`: Named results bag. Always contains "transcription" (original).
//    Steps with a `label` store snapshots here.
//  - `segments`: Set by diarize/segmentMerge steps.
//

#if os(macOS)
import Foundation

struct PipelineContext {

    // MARK: - Traveling Text

    /// The current text, updated by each text-producing step.
    /// Starts as the original transcription.
    var text: String

    // MARK: - Named Results

    /// Labeled results from processing steps.
    /// Always contains "transcription" with the original text.
    var results: [String: String]

    // MARK: - Structured Data

    /// Speaker-identified segments, set by diarize/segmentMerge steps.
    var segments: [MeetingSegment]?

    // MARK: - Audio Data

    /// Raw audio samples (available for steps that need audio, e.g. diarize).
    let samples: [Float]?
    let sampleRate: Double?

    // MARK: - Metadata

    let modeName: String
    let appName: String?
    let duration: TimeInterval?
    let date: Date
    let focusSnapshot: FocusSnapshot?

    // MARK: - Reserved Label Names

    static let reservedLabels: Set<String> = [
        "text", "transcription", "segments",
        "date", "time", "year", "month", "day",
        "timestamp", "mode_name", "app_name", "duration",
    ]

    // MARK: - Init

    init(
        transcription: String,
        samples: [Float]? = nil,
        sampleRate: Double? = nil,
        modeName: String = "",
        appName: String? = nil,
        duration: TimeInterval? = nil,
        date: Date = Date(),
        focusSnapshot: FocusSnapshot? = nil
    ) {
        self.text = transcription
        self.results = ["transcription": transcription]
        self.samples = samples
        self.sampleRate = sampleRate
        self.modeName = modeName
        self.appName = appName
        self.duration = duration
        self.date = date
        self.focusSnapshot = focusSnapshot
    }
}
#endif
