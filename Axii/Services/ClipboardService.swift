//
//  ClipboardService.swift
//  Axii
//
//  Clipboard operations with save/restore capability.
//

#if os(macOS)
import AppKit

/// Represents saved clipboard content for later restoration.
struct ClipboardContent: Sendable {
    let string: String?
}

/// Clipboard service for copying text with optional save/restore.
@MainActor
final class ClipboardService {
    /// Copy text to the system clipboard.
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Save current clipboard content for later restoration.
    func saveCurrentClipboard() -> ClipboardContent {
        let pasteboard = NSPasteboard.general
        let string = pasteboard.string(forType: .string)
        return ClipboardContent(string: string)
    }

    /// Restore previously saved clipboard content.
    func restore(_ content: ClipboardContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let string = content.string {
            pasteboard.setString(string, forType: .string)
        }
    }
}
#endif
