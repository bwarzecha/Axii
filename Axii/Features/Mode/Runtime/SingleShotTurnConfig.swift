//
//  SingleShotTurnConfig.swift
//  Axii
//
//  Narrow execution config snapshot for single-shot mode turns.
//  Contains only the post-capture execution pieces the processor needs,
//  not the full ModeConfig.
//

#if os(macOS)

struct SingleShotTurnConfig {
    let modeName: String
    let processing: [ProcessingStep]
    let outputs: [OutputDestination]
    let panelPersistence: PanelPersistence
}

#endif
