//
//  PasteService.swift
//  dictaitor
//
//  Handles text insertion via clipboard + paste keystroke.
//  Falls back to copy-only when focus changed, secure input active, or no AX permission.
//

#if os(macOS)
import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteService {
    enum Outcome: Equatable {
        case pasted
        case copiedFallback(reason: String)
        case skipped
    }

    private let clipboard: ClipboardService
    private let accessibilityPermission: AccessibilityPermissionService

    init(clipboard: ClipboardService, accessibilityPermission: AccessibilityPermissionService) {
        self.clipboard = clipboard
        self.accessibilityPermission = accessibilityPermission
    }

    func paste(text: String, focusSnapshot: FocusSnapshot?) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .skipped
        }

        let currentFocus = FocusSnapshot.capture()

        let focusChangeReason = focusSnapshot?.changeReason(comparedTo: currentFocus)
        let focusChanged = focusChangeReason != nil

        let secureInputActive = Self.isSecureInputActive()

        let canPaste = accessibilityPermission.isTrusted

        if !canPaste {
            clipboard.copy(text)
            return .copiedFallback(reason: "Accessibility permission required")
        }

        if secureInputActive {
            clipboard.copy(text)
            return .copiedFallback(reason: "Secure input active")
        }

        if focusChanged {
            clipboard.copy(text)
            let reason = focusChangeReason?.description ?? "Focus changed"
            return .copiedFallback(reason: reason)
        }

        clipboard.copy(text)
        synthesizePasteKeystroke()
        return .pasted
    }

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

    private static func isSecureInputActive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let securePID = dict["CGSSessionSecureInputPID"] as? Int else {
            return false
        }
        return securePID != 0
    }
}
#endif
