//
//  ClipboardService.swift
//  Axii
//
//  Clipboard operations.
//

#if os(macOS)
import AppKit

/// Simple clipboard service for copying text.
@MainActor
final class ClipboardService {
    /// Copy text to the system clipboard.
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
