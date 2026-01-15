//
//  AppController.swift
//  dictaitor
//
//  Thin coordinator - sets up services and features.
//  Logic lives in features, not here.
//

import AppKit

/// Application coordinator. Sets up services and registers features.
/// Feature logic is owned by the features themselves.
@MainActor
final class AppController {
    private let hotkeyService: HotkeyService
    private let featureManager: FeatureManager
    private var panelController: FloatingPanelController?

    // Features
    let dictationFeature: DictationFeature

    init() {
        // Create services
        hotkeyService = HotkeyService()
        featureManager = FeatureManager(hotkeyService: hotkeyService)

        // Create features
        dictationFeature = DictationFeature()

        // Setup
        setupPanel()
        registerFeatures()
    }

    private func setupPanel() {
        // Create panel with placeholder content
        panelController = FloatingPanelController()
        featureManager.setPanelController(panelController!)
    }

    private func registerFeatures() {
        // Features register themselves and their hotkeys
        featureManager.register(dictationFeature)

        // Future: featureManager.register(chatFeature)
    }
}
