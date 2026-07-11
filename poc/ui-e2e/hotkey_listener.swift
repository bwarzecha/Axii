// POC 1 (listener side): register a Carbon global hotkey the same way Axii
// does (RegisterEventHotKey) and print when it fires. Uses Control+Shift+F13
// so it cannot collide with Axii's real hotkeys or type into anything.
//
// Goal: prove whether CGEventPost-synthesized modifier-bearing events reach
// the WindowServer Carbon hotkey matcher on THIS macOS version — the
// macOS 26 CGXSenderCanSynthesizeEvents gate reportedly drops them for
// ad-hoc-signed posters.

import AppKit
import Carbon

let keyCode = UInt32(kVK_ANSI_9)
let modifiers = UInt32(controlKey | shiftKey)

var eventType = EventTypeSpec(
    eventClass: OSType(kEventClassKeyboard),
    eventKind: UInt32(kEventHotKeyPressed)
)

var handlerRef: EventHandlerRef?
InstallEventHandler(
    GetEventDispatcherTarget(),
    { _, _, _ in
        print("HOTKEY_FIRED")
        fflush(stdout)
        return noErr
    },
    1, &eventType, nil, &handlerRef
)

var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType(0x4158_5049), id: 1)
let status = RegisterEventHotKey(
    keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef
)
print("REGISTER_STATUS=\(status)")
fflush(stdout)

// Agent-style app run loop, like Axii (LSUIElement).
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
