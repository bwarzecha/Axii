//
//  PasteService.swift
//  Axii
//
//  Handles text insertion with multiple strategies:
//  1. Direct AX insertion (kAXSelectedTextAttribute) - no clipboard
//  2. Clipboard + paste keystroke (universal fallback)
//
//  Supports configurable behaviors for finish action and failure handling.
//

#if os(macOS)
import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteService {
    enum Outcome: Equatable {
        /// Text was successfully inserted (via AX or paste).
        case pasted
        /// Text was inserted and also left in clipboard.
        case pastedAndCopied
        /// Text was copied to clipboard as fallback (when failure behavior allows).
        case copiedFallback(reason: String)
        /// User chose copy-only mode, text is in clipboard.
        case copiedOnly
        /// Insertion failed, user needs to manually copy (copy button should be shown).
        case needsManualCopy(reason: String)
        /// Empty text, nothing was done.
        case skipped
    }

    private let clipboard: ClipboardService
    private let insertionService: TextInsertionService
    private let accessibilityPermission: AccessibilityPermissionService

    init(clipboard: ClipboardService, accessibilityPermission: AccessibilityPermissionService) {
        self.clipboard = clipboard
        self.insertionService = TextInsertionService(clipboardService: clipboard)
        self.accessibilityPermission = accessibilityPermission
    }

    /// Paste text with configurable behavior.
    /// - Parameters:
    ///   - text: Text to paste
    ///   - focusSnapshot: Captured focus state from when recording started
    ///   - finishBehavior: What to do with text (insert+copy, insert only, copy only)
    ///   - failureBehavior: What to do when insertion fails
    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .skipped
        }

        // Copy-only mode: just copy, don't paste
        if finishBehavior == .copyOnly {
            clipboard.copy(text)
            return .copiedOnly
        }

        // Check if we can paste
        let failureReason = checkPasteConditions(focusSnapshot: focusSnapshot)

        if let reason = failureReason {
            return handleInsertionFailure(
                text: text,
                reason: reason,
                failureBehavior: failureBehavior
            )
        }

        // Success path: paste the text
        return await performPaste(
            text: text,
            finishBehavior: finishBehavior
        )
    }

    /// Check conditions required for pasting. Returns failure reason or nil if OK.
    private func checkPasteConditions(focusSnapshot: FocusSnapshot?) -> String? {
        if !accessibilityPermission.isTrusted {
            return "Accessibility permission required"
        }

        if Self.isSecureInputActive() {
            return "Secure input active"
        }

        let currentFocus = FocusSnapshot.capture()
        if let reason = focusSnapshot?.changeReason(comparedTo: currentFocus) {
            return reason.description
        }

        return nil
    }

    /// Handle insertion failure based on user preference.
    private func handleInsertionFailure(
        text: String,
        reason: String,
        failureBehavior: InsertionFailureBehavior
    ) -> Outcome {
        switch failureBehavior {
        case .showCopyButton:
            // Don't copy to clipboard, let user decide
            return .needsManualCopy(reason: reason)
        case .copyFallback:
            // Copy to clipboard automatically
            clipboard.copy(text)
            return .copiedFallback(reason: reason)
        }
    }

    /// Perform the actual paste operation using TextInsertionService.
    /// Tries direct AX insertion first, falls back to clipboard+paste.
    private func performPaste(
        text: String,
        finishBehavior: FinishBehavior
    ) async -> Outcome {
        switch finishBehavior {
        case .insertAndCopy:
            // Insert text, leave it in clipboard
            let result = await insertionService.insert(text: text, restoreClipboard: false)

            switch result {
            case .insertedDirect:
                // AX insertion succeeded, clipboard untouched - copy to clipboard
                clipboard.copy(text)
                return .pastedAndCopied

            case .insertedViaPaste:
                // Clipboard was used for pasting, text is already there
                return .pastedAndCopied

            case .failed(let reason):
                return .copiedFallback(reason: reason)
            }

        case .insertOnly:
            // Insert text, restore clipboard to original content
            let result = await insertionService.insert(text: text, restoreClipboard: true)

            switch result {
            case .insertedDirect:
                // AX insertion succeeded, clipboard was never touched
                return .pasted

            case .insertedViaPaste:
                // Clipboard was used but restored after 300ms delay
                return .pasted

            case .failed(let reason):
                return .copiedFallback(reason: reason)
            }

        case .copyOnly:
            clipboard.copy(text)
            return .copiedOnly
        }
    }

    private static func isSecureInputActive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let securePID = dict["CGSSessionSecureInputPID"] as? Int else {
            return false
        }
        return securePID != 0
    }
}
#endif
