//
//  ModeExecutionBoundaries.swift
//  Axii
//
//  Narrow boundary interfaces for mode turn execution processors.
//  These exist to make processor tests stable without pinning them
//  to runtime adapter internals.
//

#if os(macOS)
import Foundation

/// The high-level hotkey execution family for a mode. This is config-driven
/// for single-shot vs multi-turn so that collaborator availability does not
/// silently change user-visible mode behavior.
enum ModeHotkeyRoute: Equatable {
    case meeting
    case multiTurn
    case singleShot

    static func select(
        hasMeetingHandler: Bool,
        config: ModeConfig
    ) -> ModeHotkeyRoute {
        if hasMeetingHandler { return .meeting }
        return config.usesMultiTurnProcessing ? .multiTurn : .singleShot
    }
}

/// Wraps PipelineRunner for processor-level testing.
@MainActor
protocol PipelineExecuting {
    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext
}

/// Wraps OutputHandler for processor-level testing.
@MainActor
protocol ModeOutputExecuting {
    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async
}

/// Dismiss control seam so processor tests can verify dismiss decisions
/// without reaching into DispatchWorkItem internals.
@MainActor
protocol ModeDismissControlling: AnyObject {
    func cancelScheduledDismiss()
    func scheduleDismiss(after delay: TimeInterval)
}

/// Narrow boundary for LLM response generation.
/// Wraps LLMService so multi-turn processor tests can verify
/// send(message:) vs send(messages:) call selection.
@MainActor
protocol ConversationResponding {
    func send(message: String) async throws -> String
    func send(messages: [Message]) async throws -> String
}

/// Narrow boundary for persisted conversation session management.
/// The store owns session creation, user-message persistence, message
/// loading, and assistant-reply persistence. It does NOT own runtime
/// state mutation, display message projection, or LLM request policy.
@MainActor
protocol ConversationSessionStoring {
    /// Prepare a turn: create or update the persisted session, return
    /// the session ID and any persisted messages for LLM context.
    func beginTurn(
        userText: String,
        currentSessionId: UUID?
    ) async throws -> PreparedConversationTurn

    /// Persist the assistant reply to an existing session.
    /// Failures are swallowed/logged — callers should not fail the visible turn.
    func appendAssistantReply(
        sessionId: UUID,
        text: String
    ) async
}

/// The result of `ConversationSessionStoring.beginTurn(...)`.
/// `sessionId` is nil when history is disabled.
/// `persistedMessages` is nil when history is disabled or on first turn.
struct PreparedConversationTurn {
    let sessionId: UUID?
    let persistedMessages: [Message]?
}

#endif
