//
//  PipelineStepExecutor.swift
//  Axii
//
//  Protocol and concrete executors for each ProcessingStep type.
//  Each executor reads what it needs from PipelineContext and writes
//  its outputs back.
//

#if os(macOS)
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "PipelineStep")

// MARK: - Protocol

protocol PipelineStepExecutor {
    func execute(context: inout PipelineContext) async throws
}

// MARK: - Diarize

final class DiarizeStepExecutor: PipelineStepExecutor {
    private let config: DiarizeConfig
    private let diarizationService: DiarizationService?

    init(config: DiarizeConfig, diarizationService: DiarizationService?) {
        self.config = config
        self.diarizationService = diarizationService
    }

    func execute(context: inout PipelineContext) async throws {
        // Note: Meeting mode labels speakers by audio source (mic = "You",
        // system = "Remote") in MeetingFinalizationService; DiarizationService
        // is not involved there. This executor covers single-source speaker
        // model diarization (future) and source-label mode for simple
        // recording with known speaker.
        guard let samples = context.samples,
              !samples.isEmpty else {
            logger.warning("Diarize step skipped: no audio data")
            return
        }

        if case .sourceLabels(let micLabel, _) = config.mode {
            let sampleRate = context.sampleRate ?? 16000
            let segment = MeetingSegment(
                text: context.text,
                speakerId: micLabel,
                isFromMicrophone: true,
                startTime: 0,
                endTime: Double(samples.count) / sampleRate
            )
            context.segments = [segment]
            logger.info("Diarize: created 1 segment with source label '\(micLabel)'")
        } else {
            // Speaker model diarization — requires DiarizationService
            guard let service = diarizationService else {
                logger.warning("Diarize step skipped: no diarization service")
                return
            }
            let timedSegments = try await service.diarizeOffline(samples: samples)
            // TODO: Text alignment requires word-level timestamps from transcription engine
            context.segments = timedSegments.map { timed in
                MeetingSegment(
                    text: "",
                    speakerId: timed.speakerId ?? "Unknown",
                    isFromMicrophone: true,
                    startTime: Double(timed.startTimeSeconds),
                    endTime: Double(timed.endTimeSeconds)
                )
            }
            logger.warning("Diarize: speaker model produced \(timedSegments.count) segment(s) without text alignment")
        }
    }
}

// MARK: - Segment Merge

final class SegmentMergeStepExecutor: PipelineStepExecutor {
    private let config: SegmentMergeConfig

    init(config: SegmentMergeConfig) {
        self.config = config
    }

    func execute(context: inout PipelineContext) async throws {
        guard config.mergeConsecutiveSameSpeaker,
              var segments = context.segments,
              segments.count > 1 else { return }

        segments.sort { $0.startTime < $1.startTime }

        var merged: [MeetingSegment] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]
            if current.speakerId == next.speakerId {
                current = MeetingSegment(
                    id: current.id,
                    text: current.text + " " + next.text,
                    speakerId: current.speakerId,
                    isFromMicrophone: current.isFromMicrophone,
                    startTime: current.startTime,
                    endTime: max(current.endTime, next.endTime)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        context.segments = merged

        logger.info("SegmentMerge: \(segments.count) → \(merged.count) segments")
    }
}

// MARK: - LLM Transform

final class LLMTransformStepExecutor: PipelineStepExecutor {
    private let config: LLMTransformConfig
    private let llmService: LLMService
    private let templateResolver: TemplateResolver

    init(
        config: LLMTransformConfig,
        llmService: LLMService,
        templateResolver: TemplateResolver
    ) {
        self.config = config
        self.llmService = llmService
        self.templateResolver = templateResolver
    }

    func execute(context: inout PipelineContext) async throws {
        // Resolve input: use promptTemplate if set, otherwise traveling text
        let input: String
        if let template = config.promptTemplate, !template.isEmpty {
            input = templateResolver.resolve(template, context: context)
        } else {
            input = context.text
        }

        // Per-step system prompt override (nil = use LLMService default)
        let prompt = config.systemPrompt.isEmpty ? nil : config.systemPrompt
        let response = try await llmService.send(message: input, systemPrompt: prompt)

        // Update traveling text
        context.text = response

        // Store labeled snapshot if configured
        if let label = config.label, !label.isEmpty {
            context.results[label] = response
        }

        let labelInfo = self.config.label.map { " (label: \($0))" } ?? ""
        logger.info("LLMTransform: produced \(response.count) chars\(labelInfo)")
    }
}
#endif
