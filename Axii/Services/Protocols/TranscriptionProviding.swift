//
//  TranscriptionProviding.swift
//  Axii
//
//  Narrow protocol for transcription, allowing test doubles.
//

#if os(macOS)
import Foundation

/// Narrow protocol for transcription, allowing test doubles.
protocol TranscriptionProviding: Sendable {
    var isReady: Bool { get async }
    func prepare() async throws
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}

/// Conform the real TranscriptionService to the protocol.
extension TranscriptionService: TranscriptionProviding {
    func prepare() async throws {
        try await prepare(modelsDirectory: nil)
    }
}
#endif
