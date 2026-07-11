//
//  AppLaunchOverrides.swift
//  Axii
//
//  Test-only launch overrides read from the environment. Production runs
//  set none of these; the E2E suite points the app at scratch storage so a
//  test run can never touch real user data.
//
//  UserDefaults-backed state (settings, per-mode mic selection) needs no
//  seam here: tests pass launch arguments ("-key", "value") and the
//  NSArgumentDomain shadows every UserDefaults.standard READ for that
//  process without writing to the real plist.
//

#if os(macOS)
import Foundation

struct AppLaunchOverrides {
    /// Environment variable names — shared contract with the E2E suite.
    enum Key {
        static let historyDirectory = "AXII_HISTORY_DIR"
        static let modesDirectory = "AXII_MODES_DIR"
        static let recoveryDirectory = "AXII_RECOVERY_DIR"
    }

    let historyDirectory: URL?
    let modesDirectory: URL?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchOverrides {
        AppLaunchOverrides(
            historyDirectory: environment[Key.historyDirectory]
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            modesDirectory: environment[Key.modesDirectory]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    /// Crash-recovery storage (autosave file + audio spool) is GLOBAL state
    /// shared by every instance of the app. A test instance must not swallow
    /// a real crashed meeting's recovery file — or leak phantom test
    /// meetings into the real app's next launch — so the recovery paths
    /// consult this directly rather than being threaded through the
    /// meeting construction graph.
    static func recoveryDirectoryOverride(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        environment[Key.recoveryDirectory]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
#endif
