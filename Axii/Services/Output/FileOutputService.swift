//
//  FileOutputService.swift
//  Axii
//
//  Writes transcription output to files based on FileOutputConfig.
//  Supports path templates with variable substitution.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "FileOutputService")

final class FileOutputService {

    func write(text: String, config: FileOutputConfig, context: FileTemplateContext) async throws {
        let resolvedPath = resolveTemplate(config.pathTemplate, context: context)
        let fileURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL

        if config.createDirectories {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        let content: String
        if let template = config.contentTemplate {
            content = resolveTemplate(template, context: context)
                .replacingOccurrences(of: "{text}", with: text)
        } else {
            content = text
        }

        switch config.writeMode {
        case .overwrite:
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

        case .append:
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                if let data = "\n\(content)".data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }

        case .newFile:
            let uniqueURL = makeUniqueURL(from: fileURL)
            try content.write(to: uniqueURL, atomically: true, encoding: .utf8)
        }

        logger.info("Wrote output to \(fileURL.path)")
    }

    // MARK: - Template Resolution

    func resolveTemplate(_ template: String, context: FileTemplateContext) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: context.date
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: context.date)

        dateFormatter.dateFormat = "HH-mm-ss"
        let timeString = dateFormatter.string(from: context.date)

        return template
            .replacingOccurrences(of: "{date}", with: dateString)
            .replacingOccurrences(of: "{time}", with: timeString)
            .replacingOccurrences(of: "{year}", with: String(format: "%04d", components.year ?? 0))
            .replacingOccurrences(of: "{month}", with: String(format: "%02d", components.month ?? 0))
            .replacingOccurrences(of: "{day}", with: String(format: "%02d", components.day ?? 0))
            .replacingOccurrences(of: "{mode_name}", with: context.modeName)
            .replacingOccurrences(of: "{app_name}", with: context.appName ?? "unknown")
            .replacingOccurrences(of: "{timestamp}", with: String(Int(context.date.timeIntervalSince1970)))
    }

    // MARK: - Private

    private func makeUniqueURL(from url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var candidate = url
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Template Context

struct FileTemplateContext {
    let date: Date
    let modeName: String
    let appName: String?

    init(date: Date = Date(), modeName: String, appName: String? = nil) {
        self.date = date
        self.modeName = modeName
        self.appName = appName
    }
}
#endif
