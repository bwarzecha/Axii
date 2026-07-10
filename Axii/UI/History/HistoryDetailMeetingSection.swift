//
//  HistoryDetailMeetingSection.swift
//  Axii
//
//  Meeting-specific content for HistoryDetailView: transcript segments,
//  dual-track playback, and re-transcription from stored audio.
//  Extracted to keep each file within line limits.
//

#if os(macOS)
import AVFoundation
import SwiftUI

extension HistoryDetailView {

    // MARK: - Meeting Content

    func meetingContent(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Meeting stats
            HStack(spacing: 16) {
                Label(formattedDuration(meeting.duration), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("\(meeting.wordCount) words", systemImage: "text.word.spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let appName = meeting.appName {
                    Label(appName, systemImage: "app.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if meeting.segments.isEmpty {
                Text("No transcript. Use Re-transcribe to build one from the recorded audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Segments
            ForEach(meeting.segments) { segment in
                meetingSegmentView(segment)
            }
        }
    }

    private func meetingSegmentView(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: segment.isFromMicrophone ? "person.fill" : "person.wave.2.fill")
                .foregroundStyle(segment.isFromMicrophone ? .blue : .green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(segment.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(segment.isFromMicrophone ? .blue : .green)

                    Text(formatTimestamp(segment.startTime))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Re-transcription

    /// Shown for any meeting with stored audio. This is the recovery path
    /// for auto-saved meetings whose transcript never got built (error
    /// exits, crash recoveries) — and a redo for better ASR models.
    @ViewBuilder
    func retranscribeControl(for meeting: Meeting) -> some View {
        if retranscriber != nil,
           meeting.micRecording != nil || meeting.systemRecording != nil {
            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView(value: retranscribeProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                    Text(retranscribeStatus.isEmpty ? "Transcribing…" : retranscribeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Button {
                    confirmAndRetranscribe(meeting)
                } label: {
                    Label("Re-transcribe", systemImage: "arrow.clockwise")
                }
                .help(meeting.segments.isEmpty
                      ? "Build a transcript from the recorded audio"
                      : "Re-run transcription and replace the transcript")
            }
        }
    }

    private func confirmAndRetranscribe(_ meeting: Meeting) {
        // Replacing an existing transcript is destructive — confirm.
        // Building a missing one is not.
        if !meeting.segments.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace transcript?"
            alert.informativeText = "This re-runs transcription over the stored audio and replaces the current transcript."
            alert.addButton(withTitle: "Re-transcribe")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runRetranscription(meeting)
    }

    private func runRetranscription(_ meeting: Meeting) {
        guard let retranscriber, !isRetranscribing else { return }
        isRetranscribing = true
        retranscribeProgress = 0
        retranscribeStatus = ""
        audioError = nil
        stopAudio()
        Task { @MainActor in
            defer { isRetranscribing = false }
            do {
                let updated = try await retranscriber.retranscribe(meeting) { progress, status in
                    retranscribeProgress = progress
                    retranscribeStatus = status
                }
                interaction = .meeting(updated)
            } catch {
                audioError = error.localizedDescription
            }
        }
    }

    // MARK: - Meeting Audio Playback

    func hasMeetingAudio(_ meeting: Meeting) -> Bool {
        switch selectedAudioTrack {
        case .you:
            return meeting.micRecording != nil
        case .remote:
            return meeting.systemRecording != nil
        case .both:
            return meeting.micRecording != nil || meeting.systemRecording != nil
        }
    }

    func toggleMeetingAudio(_ meeting: Meeting) {
        if isPlaying {
            stopAudio()
        } else {
            playMeetingAudio(meeting)
        }
    }

    private func playMeetingAudio(_ meeting: Meeting) {
        audioError = nil

        switch selectedAudioTrack {
        case .you:
            guard let recording = meeting.micRecording,
                  let url = historyService.getAudioURL(recording, for: meeting.id) else { return }
            playAudio(url: url)

        case .remote:
            guard let recording = meeting.systemRecording,
                  let url = historyService.getAudioURL(recording, for: meeting.id) else { return }
            playAudio(url: url)

        case .both:
            // Play both tracks simultaneously
            let micURL = meeting.micRecording.flatMap { historyService.getAudioURL($0, for: meeting.id) }
            let sysURL = meeting.systemRecording.flatMap { historyService.getAudioURL($0, for: meeting.id) }

            guard micURL != nil || sysURL != nil else { return }

            do {
                if let micURL {
                    let player1 = try AVAudioPlayer(contentsOf: micURL)
                    player1.prepareToPlay()
                    audioPlayer = player1
                }

                if let sysURL {
                    let player2 = try AVAudioPlayer(contentsOf: sysURL)
                    player2.prepareToPlay()
                    audioPlayer2 = player2
                }

                // Set delegate on first available player for finish callback
                let delegate = AudioPlayerDelegate { [self] in
                    isPlaying = false
                }
                audioDelegate = delegate
                audioPlayer?.delegate = delegate

                // Start both players
                audioPlayer?.play()
                audioPlayer2?.play()
                isPlaying = true
            } catch {
                audioError = "Cannot play audio: \(error.localizedDescription)"
            }
        }
    }
}
#endif
