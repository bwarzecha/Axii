//
//  AboutSettingsView.swift
//  Axii
//
//  About section with version info and update controls.
//

#if os(macOS)
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var updaterService: UpdaterService

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Axii")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Section {
                Toggle("Automatically check for updates", isOn: automaticallyChecksBinding)

                Button("Check for Updates...") {
                    updaterService.checkForUpdates()
                }
                .disabled(!updaterService.canCheckForUpdates)
            } header: {
                Text("Updates")
            }

            Section {
                Link("GitHub Repository", destination: URL(string: "https://github.com/bwarzecha/Axii")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/bwarzecha/Axii/issues")!)
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updaterService.automaticallyChecksForUpdates },
            set: { updaterService.automaticallyChecksForUpdates = $0 }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}
#endif
