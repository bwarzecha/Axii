// Fire a global hotkey via CGEventPost to the HID tap (the Maccy pattern,
// validated by the listener/poster POC on this machine).
//
// Usage: fire_hotkey <keycode> <mods>   e.g. fire_hotkey 49 opt
//        mods: comma-separated of ctrl,shift,opt,cmd

import Carbon
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let keyCode = UInt16(CommandLine.arguments[1]) else {
    print("usage: fire_hotkey <keycode> <ctrl,shift,opt,cmd>")
    exit(2)
}
var flags: CGEventFlags = []
for mod in CommandLine.arguments[2].split(separator: ",") {
    switch mod {
    case "ctrl": flags.insert(.maskControl)
    case "shift": flags.insert(.maskShift)
    case "opt": flags.insert(.maskAlternate)
    case "cmd": flags.insert(.maskCommand)
    default: print("unknown modifier \(mod)"); exit(2)
    }
}

guard AXIsProcessTrusted() else {
    print("NOT_TRUSTED")
    exit(1)
}

let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    guard let event = CGEvent(
        keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down
    ) else { exit(1) }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("FIRED key=\(keyCode) flags=\(CommandLine.arguments[2])")
