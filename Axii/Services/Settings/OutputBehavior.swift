//
//  OutputBehavior.swift
//  Axii
//
//  Enums for configuring text output behavior after transcription.
//

/// What to do with transcribed text after recording finishes.
enum FinishBehavior: String, Codable, CaseIterable {
    /// Copy to clipboard and paste (current default).
    /// Text remains in clipboard after operation.
    case insertAndCopy

    /// Paste via clipboard, then restore original clipboard contents.
    /// Keeps user's clipboard clean.
    case insertOnly

    /// Just copy to clipboard without pasting.
    /// User must manually paste.
    case copyOnly

    var displayName: String {
        switch self {
        case .insertAndCopy: return "Insert & Copy"
        case .insertOnly: return "Insert Only"
        case .copyOnly: return "Copy Only"
        }
    }

    var description: String {
        switch self {
        case .insertAndCopy:
            return "Paste text and keep it in clipboard"
        case .insertOnly:
            return "Paste text, restore original clipboard"
        case .copyOnly:
            return "Copy to clipboard without pasting"
        }
    }
}

/// What to do when text insertion fails (focus changed, secure input, no permission).
enum InsertionFailureBehavior: String, Codable, CaseIterable {
    /// Keep panel open with a copy button.
    /// User manually copies when ready. Does not pollute clipboard.
    case showCopyButton

    /// Automatically copy to clipboard and dismiss (original behavior).
    case copyFallback

    var displayName: String {
        switch self {
        case .showCopyButton: return "Show Copy Button"
        case .copyFallback: return "Copy to Clipboard"
        }
    }

    var description: String {
        switch self {
        case .showCopyButton:
            return "Keep panel open with a Copy button"
        case .copyFallback:
            return "Automatically copy and dismiss"
        }
    }
}
