//
//  StableTextEditor.swift
//  Axii
//
//  A TextEditor whose editing is decoupled from its parent's re-renders.
//
//  Why this exists: the mode editor lays its template/prompt fields out in a
//  ForEach over config.processing / config.outputs. Binding a TextEditor
//  directly to those collections means every keystroke mutates the ForEach's
//  data, SwiftUI structurally rebuilds the row, the TextEditor's inline
//  Binding is reconstructed, and NSTextView re-pushes the whole string —
//  snapping the insertion point to the end. Typing in the middle of a
//  template became impossible.
//
//  This view holds the text in its OWN @State. Typing mutates only that
//  local state (stable view identity, no parent churn), and changes flow
//  outward through onChange. The external value flows back in ONLY when it
//  diverges from what we already show — i.e. a programmatic change (reset,
//  switching modes), never the echo of our own keystroke.
//

#if os(macOS)
import SwiftUI

struct StableTextEditor: View {
    /// The model's current value. Read to seed and to detect external changes;
    /// never written directly (writes go through onChange).
    let text: String
    let onChange: (String) -> Void

    @State private var draft: String
    /// The external value we last reconciled against, so we can tell an
    /// external change apart from the echo of our own edit.
    @State private var lastExternal: String

    init(text: String, onChange: @escaping (String) -> Void) {
        self.text = text
        self.onChange = onChange
        _draft = State(initialValue: text)
        _lastExternal = State(initialValue: text)
    }

    var body: some View {
        TextEditor(text: $draft)
            .onChange(of: draft) { _, newValue in
                // Our own edit: report it, and mark it as reconciled so the
                // incoming `text` (once the model round-trips) is not treated
                // as an external change that would rewrite the field.
                lastExternal = newValue
                onChange(newValue)
            }
            .onChange(of: text) { _, newValue in
                // The model changed from the outside (reset, mode switch). Only
                // then do we overwrite the draft; this cannot fire for the echo
                // of a keystroke because that value already equals lastExternal.
                guard newValue != lastExternal else { return }
                lastExternal = newValue
                draft = newValue
            }
    }
}
#endif
