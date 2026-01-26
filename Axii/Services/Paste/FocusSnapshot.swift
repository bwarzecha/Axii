//
//  FocusSnapshot.swift
//  Axii
//
//  Captures the current focus state to detect if user switched apps/fields during recording.
//  Adapted from Starling.
//

#if os(macOS)
import AppKit
import ApplicationServices

struct FocusSnapshot: Equatable {
    struct ElementSignature: Equatable {
        let role: String?
        let subrole: String?
        let identifier: String?
        let windowNumber: Int?
    }

    /// Text surrounding the cursor position (for LLM context)
    struct SurroundingText: Equatable, Codable {
        let before: String    // Text before cursor/selection
        let selected: String  // Currently selected text
        let after: String     // Text after cursor/selection

        static let maxLength = 500  // Characters per direction
        static let maxWindowTitleLength = 200
    }

    enum ChangeReason: Equatable {
        case missingBaseline
        case missingCurrent
        case applicationChanged(previous: pid_t, current: pid_t)
        case elementSignatureChanged
        case selectionSignatureChanged

        var description: String {
            switch self {
            case .missingBaseline:
                return "baseline focus snapshot unavailable"
            case .missingCurrent:
                return "unable to capture current focus state"
            case let .applicationChanged(previous, current):
                return "frontmost application changed (\(previous) → \(current))"
            case .elementSignatureChanged:
                return "focused element signature differs"
            case .selectionSignatureChanged:
                return "text selection signature differs"
            }
        }
    }

    let appPID: pid_t
    let elementSignature: ElementSignature
    let selectionSignature: String?

    // Rich context for LLM use
    let appName: String?
    let windowTitle: String?
    let surroundingText: SurroundingText?

    /// Bundle identifier of the frontmost app (e.g., "com.apple.Safari")
    var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: appPID)?.bundleIdentifier
    }

    private static let windowNumberAttribute: CFString = "AXWindowNumber" as CFString

    static func capture() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        // Try to get focused element, but don't fail completely if unavailable
        var element: AXUIElement?
        var signature = ElementSignature(role: nil, subrole: nil, identifier: nil, windowNumber: nil)
        var range: String?

        if (status == .success || status == .noValue), let elementRef = focusedElement {
            element = (elementRef as! AXUIElement)
            signature = captureElementSignature(for: element!)
            range = captureTextRange(for: element!)
        }

        // Rich context - try from focused element first, fall back to app-level
        let appName = app.localizedName
        let windowTitle = element != nil
            ? captureWindowTitle(for: element!)
            : captureWindowTitleFromApp(appElement)

        // Capture surrounding text - try both methods and combine
        var surroundingText: SurroundingText?
        if let el = element {
            let fullContext = captureSurroundingText(for: el)
            let selectedOnly = captureSelectedTextOnly(for: el)

            if let full = fullContext {
                // Use full context, but prefer selected text from direct attribute if available
                let selected = selectedOnly?.selected ?? full.selected
                surroundingText = SurroundingText(before: full.before, selected: selected, after: full.after)
            } else if let sel = selectedOnly {
                // Only have selected text (e.g., Electron apps)
                surroundingText = sel
            }
        }

        return FocusSnapshot(
            appPID: app.processIdentifier,
            elementSignature: signature,
            selectionSignature: range,
            appName: appName,
            windowTitle: windowTitle,
            surroundingText: surroundingText
        )
    }

    /// Get window title from app's focused window (fallback for Electron apps)
    private static func captureWindowTitleFromApp(_ appElement: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard status == .success, let windowValue = windowRef else {
            return nil
        }

        let windowElement = windowValue as! AXUIElement
        guard let title = copyStringAttribute(windowElement, kAXTitleAttribute as CFString) else {
            return nil
        }

        if title.count > SurroundingText.maxWindowTitleLength {
            return String(title.prefix(SurroundingText.maxWindowTitleLength))
        }
        return title
    }

    func changeReason(comparedTo other: FocusSnapshot?) -> ChangeReason? {
        guard let other else {
            return .missingCurrent
        }
        if appPID != other.appPID {
            return .applicationChanged(previous: appPID, current: other.appPID)
        }
        if elementSignature != other.elementSignature {
            return .elementSignatureChanged
        }
        if selectionSignature != other.selectionSignature {
            return .selectionSignatureChanged
        }
        return nil
    }

    private static func captureElementSignature(for element: AXUIElement) -> ElementSignature {
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)
        let identifier = copyStringAttribute(element, kAXIdentifierAttribute as CFString)
        let windowNumber = captureWindowNumber(for: element)
        return ElementSignature(
            role: role,
            subrole: subrole,
            identifier: identifier,
            windowNumber: windowNumber
        )
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }

        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func captureWindowNumber(for element: AXUIElement) -> Int? {
        var windowRef: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowRef
        )
        guard windowStatus == .success, let windowValue = windowRef else {
            return nil
        }

        let windowElement = windowValue as! AXUIElement
        var numberValue: CFTypeRef?
        let numberStatus = AXUIElementCopyAttributeValue(
            windowElement,
            windowNumberAttribute,
            &numberValue
        )

        if numberStatus == .success, let number = numberValue as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func captureTextRange(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success, let rangeValue = value else {
            return nil
        }

        let axValue = rangeValue as! AXValue
        var range = CFRange(location: 0, length: 0)
        if AXValueGetType(axValue) == .cfRange,
           AXValueGetValue(axValue, .cfRange, &range) {
            return "\(range.location):\(range.length)"
        }
        return String(describing: axValue)
    }

    private static func captureWindowTitle(for element: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowRef
        )
        guard windowStatus == .success, let windowValue = windowRef else {
            return nil
        }

        let windowElement = windowValue as! AXUIElement
        guard let title = copyStringAttribute(windowElement, kAXTitleAttribute as CFString) else {
            return nil
        }

        // Truncate if too long
        if title.count > SurroundingText.maxWindowTitleLength {
            return String(title.prefix(SurroundingText.maxWindowTitleLength))
        }
        return title
    }

    private static func captureSurroundingText(for element: AXUIElement) -> SurroundingText? {
        // Get full text value
        guard let fullText = copyStringAttribute(element, kAXValueAttribute as CFString),
              !fullText.isEmpty else {
            return nil
        }

        // Get selection range
        var rangeValue: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        let nsString = fullText as NSString
        let maxLen = SurroundingText.maxLength

        // No selection info - return text from end (cursor likely at end)
        guard rangeStatus == .success, let rangeRef = rangeValue else {
            let start = max(0, nsString.length - maxLen)
            let text = nsString.substring(from: start)
            return SurroundingText(before: text, selected: "", after: "")
        }

        let axValue = rangeRef as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range) else {
            let start = max(0, nsString.length - maxLen)
            let text = nsString.substring(from: start)
            return SurroundingText(before: text, selected: "", after: "")
        }

        let selStart = max(0, min(range.location, nsString.length))
        let selEnd = max(0, min(range.location + range.length, nsString.length))

        // Extract before, selected, after
        let beforeStart = max(0, selStart - maxLen)
        let afterEnd = min(nsString.length, selEnd + maxLen)

        let before = nsString.substring(with: NSRange(location: beforeStart, length: selStart - beforeStart))
        let selected = selEnd > selStart
            ? nsString.substring(with: NSRange(location: selStart, length: selEnd - selStart))
            : ""
        let after = nsString.substring(with: NSRange(location: selEnd, length: afterEnd - selEnd))

        return SurroundingText(before: before, selected: selected, after: after)
    }

    /// Fallback: get only the selected text (works in more apps including some Electron)
    private static func captureSelectedTextOnly(for element: AXUIElement) -> SurroundingText? {
        guard let selectedText = copyStringAttribute(element, kAXSelectedTextAttribute as CFString),
              !selectedText.isEmpty else {
            return nil
        }

        return SurroundingText(before: "", selected: selectedText, after: "")
    }
}
#endif
