//
//  DisplayMessage.swift
//  Axii
//
//  A display message for conversation UIs (simpler than the history
//  Message). Used by ModeRuntimeState and the multi-turn processor.
//  (Extracted from the deleted legacy ConversationState.swift.)
//

import Foundation

struct DisplayMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    let content: String

    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    /// Create from history Message
    init(from message: Message) {
        self.id = message.id
        self.role = message.role
        self.content = message.content
    }
}
