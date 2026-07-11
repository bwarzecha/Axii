// Ask TCC to prompt: this makes macOS add the RESPONSIBLE bundle to the
// Accessibility list (unchecked), revealing exactly which identity to grant.
import ApplicationServices
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
print("AX_TRUSTED=\(trusted) (if false, check System Settings > Accessibility for a new unchecked entry)")
