//
//  UpdaterService.swift
//  Axii
//
//  Wrapper around Sparkle's SPUUpdater for auto-update functionality.
//

#if os(macOS)
import Foundation
import Sparkle
import Combine

@MainActor
final class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    @Published var canCheckForUpdates = false

    /// Whether automatic update checks are enabled.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    init() {
        // Initialize with automatic start
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe canCheckForUpdates property
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)
    }

    /// Manually trigger an update check.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#endif
