//
//  TextInsertionService.swift
//  Axii
//
//  Multi-strategy text insertion using Accessibility API first,
//  falling back to clipboard+paste when needed.
//
//  Strategy order:
//  1. kAXSelectedTextAttribute (direct, no clipboard)
//  2. Clipboard + Cmd+V paste (universal, with clipboard restore)
//

#if os(macOS)
import ApplicationServices
import AppKit
import Carbon.HIToolbox

@MainActor
final class TextInsertionService {
    enum InsertionResult: Equatable {
        /// Text was inserted directly via Accessibility API (clipboard untouched)
        case insertedDirect
        /// Text was inserted via clipboard+paste, clipboard restored to original
        case insertedViaPaste
        /// Insertion failed, text is NOT in clipboard
        case failed(reason: String)
    }

    /// Standard pasteboard type to mark content as transient (for clipboard history apps)
    /// See: http://nspasteboard.org/
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let clipboardService: ClipboardService

    init(clipboardService: ClipboardService) {
        self.clipboardService = clipboardService
    }

    /// Insert text using best available method.
    /// Tries direct AX insertion first, falls back to clipboard+paste.
    ///
    /// - Parameter restoreClipboard: If true, restore original clipboard after paste
    /// - Returns: Result indicating which method succeeded
    func insert(text: String, restoreClipboard: Bool) async -> InsertionResult {
        // Strategy 1: Try direct AX insertion (no clipboard)
        if insertViaSelectedText(text) {
            return .insertedDirect
        }

        // Strategy 2: Clipboard + Cmd+V paste
        let savedClipboard = restoreClipboard ? clipboardService.saveCurrentClipboard() : nil

        // Copy text to clipboard with transient marker
        copyToClipboard(text)

        // Small delay to ensure clipboard is ready
        try? await Task.sleep(for: .milliseconds(20))

        synthesizePasteKeystroke()

        // Restore clipboard if requested
        if let saved = savedClipboard {
            // Wait for target app to read clipboard before restoring
            try? await Task.sleep(for: .milliseconds(300))
            clipboardService.restore(saved)
        }

        return .insertedViaPaste
    }

    /// Copy text to clipboard with transient marker so clipboard history apps ignore it.
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Use NSPasteboardItem for reliable multi-type content
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
    }

    // MARK: - AX Insertion

    /// Insert text using kAXSelectedTextAttribute.
    /// This inserts at cursor position without touching clipboard.
    private func insertViaSelectedText(_ text: String) -> Bool {
        guard let focusedElement = getFocusedElement() else {
            return false
        }

        // Get value before insertion for verification
        let valueBefore = getElementValue(focusedElement)

        // Try to set selected text directly
        let result = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )

        if result == .success {
            // Verify insertion actually happened
            if verifyInsertion(element: focusedElement, insertedText: text, valueBefore: valueBefore) {
                return true
            }
        }

        return false
    }

    /// Get the currently focused UI element.
    private func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        var focusedElement: CFTypeRef?
        let elementResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard elementResult == .success, let element = focusedElement else {
            return nil
        }

        return (element as! AXUIElement)
    }

    /// Get the AXValue of an element (text content).
    private func getElementValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )

        guard result == .success, let stringValue = value as? String else {
            return nil
        }

        return stringValue
    }

    /// Verify that text was actually inserted.
    /// Some apps (Chrome, Electron) falsely report success.
    private func verifyInsertion(element: AXUIElement, insertedText: String, valueBefore: String?) -> Bool {
        // Small delay to let insertion complete (sync is fine here, just 10ms)
        usleep(10000) // 10ms

        let valueAfter = getElementValue(element)

        // If we can't read the value, assume success (some fields don't support AXValue)
        guard valueAfter != nil || valueBefore != nil else {
            return true
        }

        // Check if value changed
        if valueBefore != valueAfter {
            return true
        }

        // Value didn't change - likely false success
        return false
    }

    // MARK: - Clipboard Paste

    private func synthesizePasteKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }
}
#endif
