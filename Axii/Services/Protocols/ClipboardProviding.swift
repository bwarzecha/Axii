//
//  ClipboardProviding.swift
//  Axii
//
//  Seam for clipboard writes. Tests and fuzzers inject a recorder: the real
//  service writes NSPasteboard.general — fuzzed copy paths (export
//  copy-and-dismiss, stop-and-preserve of a history-off meeting) would
//  otherwise clobber the developer's actual clipboard on every local run
//  and pay real pboard XPC latency on CI, perturbing seeded schedules.
//

#if os(macOS)

@MainActor
protocol ClipboardProviding: AnyObject {
    func copy(_ text: String)
}

extension ClipboardService: ClipboardProviding {}

#endif
