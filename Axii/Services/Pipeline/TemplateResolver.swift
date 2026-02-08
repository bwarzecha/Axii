//
//  TemplateResolver.swift
//  Axii
//
//  Centralized template variable resolution with modifier support.
//
//  Variables:
//    {transcription}  — original transcription (always available)
//    {text}           — traveling text (current/final result)
//    {segments}       — auto-flattened meeting segments
//    {any_label}      — user-defined label from processing step
//    {date}, {time}, {year}, {month}, {day} — date/time
//    {timestamp}      — Unix timestamp
//    {mode_name}      — mode name
//    {app_name}       — focused app name
//    {duration}       — recording duration
//
//  Modifiers (via {variable:modifier}):
//    Date:     {date:yyyy-MM-dd}, {date:MMM d, yyyy}
//    Time:     {time:HH:mm:ss}
//    Duration: {duration:mm:ss}, {duration:minutes}
//    Segments: {segments:markdown}, {segments:plain}, {segments:json}
//    Text:     {text:trimmed}, {text:uppercase}, {text:lowercase}
//

#if os(macOS)
import Foundation

final class TemplateResolver {

    // Matches {variableName} or {variableName:modifier}
    private static let variablePattern = try! NSRegularExpression(
        pattern: #"\{([a-zA-Z_][a-zA-Z0-9_]*)(?::([^}]+))?\}"#
    )

    func resolve(_ template: String, context: PipelineContext) -> String {
        let nsTemplate = template as NSString
        let matches = Self.variablePattern.matches(
            in: template, range: NSRange(location: 0, length: nsTemplate.length)
        )

        guard !matches.isEmpty else { return template }

        var result = ""
        var lastEnd = template.startIndex

        for match in matches {
            let fullRange = Range(match.range, in: template)!
            result += template[lastEnd..<fullRange.lowerBound]

            let nameRange = Range(match.range(at: 1), in: template)!
            let name = String(template[nameRange])

            let modifier: String?
            if match.range(at: 2).location != NSNotFound,
               let modRange = Range(match.range(at: 2), in: template) {
                modifier = String(template[modRange])
            } else {
                modifier = nil
            }

            result += resolveVariable(name, modifier: modifier, context: context)
            lastEnd = fullRange.upperBound
        }

        result += template[lastEnd...]
        return result
    }

    // MARK: - Variable Resolution

    private func resolveVariable(
        _ name: String,
        modifier: String?,
        context: PipelineContext
    ) -> String {
        switch name {
        case "text":
            return applyTextModifier(context.text, modifier: modifier)
        case "transcription":
            let original = context.results["transcription"] ?? context.text
            return applyTextModifier(original, modifier: modifier)
        case "segments":
            return formatSegments(context.segments ?? [], modifier: modifier)
        case "date":
            return formatDate(context.date, component: .date, modifier: modifier)
        case "time":
            return formatDate(context.date, component: .time, modifier: modifier)
        case "year":
            return dateComponent(.year, from: context.date)
        case "month":
            return dateComponent(.month, from: context.date)
        case "day":
            return dateComponent(.day, from: context.date)
        case "timestamp":
            return String(Int(context.date.timeIntervalSince1970))
        case "mode_name":
            return context.modeName
        case "app_name":
            return context.appName ?? "unknown"
        case "duration":
            return formatDuration(context.duration, modifier: modifier)
        default:
            // Check user-defined labels
            if let value = context.results[name] {
                return applyTextModifier(value, modifier: modifier)
            }
            // Unknown variable — leave as-is
            if let modifier {
                return "{\(name):\(modifier)}"
            }
            return "{\(name)}"
        }
    }

    // MARK: - Text Modifiers

    private func applyTextModifier(_ text: String, modifier: String?) -> String {
        guard let modifier else { return text }
        switch modifier {
        case "trimmed":
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "uppercase":
            return text.uppercased()
        case "lowercase":
            return text.lowercased()
        case "first_line":
            return text.components(separatedBy: .newlines).first ?? text
        default:
            return text
        }
    }

    // MARK: - Segment Formatting

    private func formatSegments(
        _ segments: [MeetingSegment],
        modifier: String?
    ) -> String {
        guard !segments.isEmpty else { return "" }
        let style = modifier ?? "plain"

        switch style {
        case "markdown":
            return segments.map { segment in
                let time = formatTimestamp(segment.startTime)
                return "**\(segment.speakerId)** (\(time))\n\(segment.text)"
            }.joined(separator: "\n\n")

        case "json":
            let items = segments.map { segment in
                """
                {"speaker": "\(jsonEscape(segment.speakerId))", \
                "text": "\(jsonEscape(segment.text))", \
                "start": \(segment.startTime), "end": \(segment.endTime)}
                """
            }
            return "[\n\(items.joined(separator: ",\n"))\n]"

        default: // "plain"
            return segments.map { segment in
                "\(segment.speakerId): \(segment.text)"
            }.joined(separator: "\n\n")
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func jsonEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Date/Time Formatting

    private enum DateComponent {
        case date, time
    }

    private func formatDate(
        _ date: Date,
        component: DateComponent,
        modifier: String?
    ) -> String {
        let formatter = DateFormatter()
        if let modifier {
            formatter.dateFormat = modifier
        } else {
            switch component {
            case .date: formatter.dateFormat = "yyyy-MM-dd"
            case .time: formatter.dateFormat = "HH-mm-ss"
            }
        }
        return formatter.string(from: date)
    }

    private func dateComponent(
        _ component: Calendar.Component,
        from date: Date
    ) -> String {
        let value = Calendar.current.component(component, from: date)
        switch component {
        case .year: return String(format: "%04d", value)
        case .month, .day: return String(format: "%02d", value)
        default: return String(value)
        }
    }

    // MARK: - Duration Formatting

    private func formatDuration(
        _ duration: TimeInterval?,
        modifier: String?
    ) -> String {
        guard let duration else { return "0:00" }
        let style = modifier ?? "mm:ss"

        switch style {
        case "minutes":
            return String(format: "%.1f", duration / 60.0)
        case "seconds":
            return String(Int(duration))
        default: // "mm:ss"
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return String(format: "%d:%02d", mins, secs)
        }
    }
}
#endif
