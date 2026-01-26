import Foundation

/// Rich context captured when dictation started (for LLM corrections)
struct FocusContext: Codable, Equatable {
    let appBundleId: String?
    let appName: String?
    let windowTitle: String?
    let surroundingText: FocusSnapshot.SurroundingText?
    let capturedAt: Date

    /// Create from a FocusSnapshot
    init(from snapshot: FocusSnapshot) {
        self.appBundleId = snapshot.bundleIdentifier
        self.appName = snapshot.appName
        self.windowTitle = snapshot.windowTitle
        self.surroundingText = snapshot.surroundingText
        self.capturedAt = Date()
    }

    init(
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        surroundingText: FocusSnapshot.SurroundingText? = nil,
        capturedAt: Date = Date()
    ) {
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.surroundingText = surroundingText
        self.capturedAt = capturedAt
    }
}
