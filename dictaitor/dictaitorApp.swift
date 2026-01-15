//
//  DictAItorApp.swift
//  DictAItorApp
//
//  Created by Bartosz on 1/14/26.
//

import SwiftUI


#if os(macOS)
import Combine  // Required for @Published to work
import HotKey   // Global hotkey support
#endif


#if os(macOS)
/// Manages global hotkey and popover visibility state.
/// Must be a class (not struct) so it persists across view updates.
/// @MainActor ensures all property access happens on the main thread.
@MainActor
class AppState: ObservableObject {
    /// When true, the popover should be visible. MenuBarExtra doesn't directly
    /// support programmatic show/hide, so we track this for UI feedback.
    @Published var isListening = false
    
    /// Holds a reference to the hotkey registration.
    /// If this is deallocated, the hotkey stops working.
    private var hotKey: HotKey?
    
    init() {
        setupHotKey()
    }
    
    private func setupHotKey() {
        // .option is the ⌥ key, .space is spacebar
        hotKey = HotKey(key: .space, modifiers: [.option])
        
        // This closure is called whenever ⌥Space is pressed, regardless of
        // which app is focused. It runs on an arbitrary thread.
        hotKey?.keyDownHandler = { [weak self] in
            // Hop to main thread before modifying @Published property
            Task { @MainActor in
                self?.isListening.toggle()
                print("Hotkey pressed, isListening: \(self?.isListening ?? false)")
            }
        }
    }
}
#endif

@main
struct DictAItorApp: App {
    #if os(macOS)
    // @StateObject creates AppState once and keeps it alive
    @StateObject private var appState = AppState()
    #endif
    var body: some Scene {
#if os(macOS)
       MenuBarExtra("DictAItor", systemImage: "waveform") {
           VStack(spacing: 12) {
               // Show different UI based on listening state
               Image(systemName: appState.isListening ? "waveform" : "mic")
                   .font(.system(size: 32))
                   .foregroundColor(appState.isListening ? .blue : .secondary)
               
               Text(appState.isListening ? "Listening..." : "Press ⌥Space")
                   .font(.headline)
               
               // Manual toggle button (useful for testing)
               Button(appState.isListening ? "Stop" : "Start") {
                   appState.isListening.toggle()
               }
               
               Divider()
               
               Button("Quit") {
                   NSApplication.shared.terminate(nil)
               }
           }
           .padding()
           .frame(width: 220, height: 160)
       }
       .menuBarExtraStyle(.window)
        
        #else
        // iPhone uses a standard window
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
