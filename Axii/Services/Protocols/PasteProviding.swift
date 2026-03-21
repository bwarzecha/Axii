//
//  PasteProviding.swift
//  Axii
//
//  Narrow protocol for paste behavior, allowing test doubles.
//

#if os(macOS)
import Foundation

/// Narrow protocol for paste behavior, allowing test doubles.
@MainActor
protocol PasteProviding {
    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome
}

/// Conform the real PasteService to the protocol.
extension PasteService: PasteProviding {}
#endif
