//
//  OnboardingView.swift
//  Axii
//
//  Permission onboarding flow - shows when mic or accessibility not granted.
//

#if os(macOS)
import SwiftUI

struct OnboardingView: View {
    let micPermission: MicrophonePermissionService
    let accessibilityPermission: AccessibilityPermissionService
    let downloadService: ModelDownloadService
    let onComplete: () -> Void

    @State private var currentPage = 0
    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ZStack {
                switch currentPage {
                case 0:
                    WelcomePage()
                        .transition(pageTransition)
                case 1:
                    MicrophonePage(permission: micPermission)
                        .transition(pageTransition)
                case 2:
                    AccessibilityPage(permission: accessibilityPermission)
                        .transition(pageTransition)
                case 3:
                    ModelDownloadPage(
                        downloadService: downloadService,
                        onComplete: onComplete
                    )
                    .transition(pageTransition)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentPage)

            // Page indicators
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 16)

            // Navigation
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation { currentPage -= 1 }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if currentPage < totalPages - 1 {
                    Button("Next") {
                        withAnimation { currentPage += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 580)
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        )
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Welcome to Axii")
                .font(.largeTitle)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Press Control+Shift+Space to record")
                FeatureRow(icon: "waveform", text: "Speak naturally, press again to stop")
                FeatureRow(icon: "cpu", text: "Transcription runs locally on your Mac")
                FeatureRow(icon: "text.cursor", text: "Text pastes at your cursor")
            }
            .padding(.horizontal, 40)

            Text("Let's set up permissions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

private struct MicrophonePage: View {
    let permission: MicrophonePermissionService
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Microphone Access")
                .font(.title)
                .bold()

            Text("Axii needs microphone access to transcribe your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if permission.state.isAuthorized {
                PermissionGrantedBadge(text: "Microphone access granted")
            } else {
                VStack(spacing: 12) {
                    // Always show request button - it will trigger the permission
                    // dialog or force TCC to register the app
                    Button("Request Microphone Access") {
                        requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequesting)

                    // Also show settings button if permission appears blocked
                    if permission.state.isBlocked {
                        Button("Open Microphone Settings") {
                            permission.openSystemSettings()
                        }
                        .buttonStyle(.bordered)

                        Text("If no dialog appears, enable manually in System Settings")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
        }
        .padding(32)
        .onAppear { permission.refresh() }
    }

    private func requestPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            _ = await permission.requestAccess()
            isRequesting = false
        }
    }
}

private struct AccessibilityPage: View {
    let permission: AccessibilityPermissionService

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 64))
                .foregroundColor(.purple)

            Text("Accessibility Access")
                .font(.title)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Axii needs Accessibility to:")
                    .font(.body)

                FeatureRow(icon: "command", text: "Simulate paste keystrokes")
                FeatureRow(icon: "cursorarrow.rays", text: "Detect cursor location")
            }
            .padding(.horizontal, 40)

            if permission.isTrusted {
                PermissionGrantedBadge(text: "Accessibility access granted")
            } else {
                VStack(spacing: 12) {
                    Button("Open Accessibility Settings") {
                        permission.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("After granting access, it will be detected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .padding(32)
        .onAppear { permission.refresh() }
    }
}

// MARK: - Components

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
}

private struct PermissionGrantedBadge: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(text)
                .foregroundColor(.green)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }
}

#endif
