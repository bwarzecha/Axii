// POC 1 (poster side): synthesize Control+Shift+F13 via CGEventPost to the
// HID tap — the Maccy technique for firing another app's Carbon hotkey.
// Prints whether this process is Accessibility-trusted first, because
// cross-process CGEventPost has required that since macOS 10.14.

import AppKit
import Carbon
import CoreGraphics

let trusted = AXIsProcessTrusted()
print("AX_TRUSTED=\(trusted)")
fflush(stdout)

let src = CGEventSource(stateID: .hidSystemState)
let keyCode = CGKeyCode(kVK_ANSI_9)

// Maccy pattern: modifier flags carried on the key events themselves.
for down in [true, false] {
    guard let event = CGEvent(
        keyboardEventSource: src, virtualKey: keyCode, keyDown: down
    ) else {
        print("EVENT_CREATE_FAILED")
        exit(1)
    }
    event.flags = [.maskControl, .maskShift]
    event.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("POSTED_FLAGS_VARIANT")
fflush(stdout)

// Belt-and-braces variant: explicit modifier key-down/up sequence around the
// key press, in case the flags-only form is what the gate drops.
usleep(300_000)
func post(_ key: Int, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(
        keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down
    ) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(40_000)
}
post(kVK_Control, down: true, flags: [.maskControl])
post(kVK_Shift, down: true, flags: [.maskControl, .maskShift])
post(kVK_ANSI_9, down: true, flags: [.maskControl, .maskShift])
post(kVK_ANSI_9, down: false, flags: [.maskControl, .maskShift])
post(kVK_Shift, down: false, flags: [.maskControl])
post(kVK_Control, down: false, flags: [])
print("POSTED_SEQUENCE_VARIANT")
