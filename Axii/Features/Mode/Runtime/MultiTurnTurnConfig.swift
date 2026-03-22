//
//  MultiTurnTurnConfig.swift
//  Axii
//
//  Narrow execution config snapshot for multi-turn mode turns.
//  Contains only the post-capture execution pieces the processor needs,
//  not the full ModeConfig.
//

#if os(macOS)

struct MultiTurnTurnConfig {
    let llmTransform: LLMTransformConfig
}

#endif
