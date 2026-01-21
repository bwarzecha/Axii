import Foundation

/// Role of a message in a conversation
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
    case tool        // Future: MCP tool responses
}

/// Future MCP support - tool call made by assistant
struct ToolCall: Codable, Equatable {
    let id: String
    let name: String
    let arguments: String   // JSON string
}

/// Future MCP support - result from a tool call
struct ToolResult: Codable, Equatable {
    let toolCallId: String
    let content: String
    let isError: Bool
}

/// A single message in a conversation
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var audioRecordingId: UUID?     // Links to AudioRecording (user messages)
    var toolCalls: [ToolCall]?      // For assistant messages (future MCP)
    var toolResult: ToolResult?     // For tool response messages (future MCP)

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        audioRecordingId: UUID? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.audioRecordingId = audioRecordingId
        self.toolCalls = toolCalls
        self.toolResult = toolResult
    }
}
