//
//  FileOutputService.swift
//  Axii
//
//  Writes transcription output to files based on FileOutputConfig.
//  Uses TemplateResolver for path and content template resolution.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "FileOutputService")

final class FileOutputService {

    func write(
        config: FileOutputConfig,
        context: PipelineContext,
        templateResolver: TemplateResolver
    ) async throws {
        let resolvedPath = templateResolver.resolve(config.pathTemplate, context: context)
        let expandedPath = NSString(string: resolvedPath).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL

        if config.createDirectories {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        let content: String
        if let template = config.contentTemplate, !template.isEmpty {
            content = templateResolver.resolve(template, context: context)
        } else {
            content = context.text
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
#endif
