# Test Fixtures

Committed JSON files that capture persisted data formats for decode-compatibility testing.

**These files are characterization fixtures. They must not be modified by automated test runs.**

## Structure

- `Modes/` — ModeConfig fixtures for each built-in mode and a sample custom mode.
- `History/Transcription/` — InteractionMetadata and Interaction for a transcription entry.
- `History/Conversation/` — InteractionMetadata and Interaction for a conversation entry.
- `History/Meeting/` — InteractionMetadata and Interaction for a meeting entry.

## Naming Convention

- `builtin-<mode>-vcurrent.json` — Current version of a built-in mode config.
- `custom-sample-vcurrent.json` — Sample custom mode config.
- `<type>-metadata.json` / `<type>-interaction.json` — Mirror the on-disk history layout.

History fixture filenames are prefixed with the interaction type to avoid
bundle resource conflicts (Xcode flattens subdirectories when copying resources).

## Encoding

Mode fixtures were generated using the app's actual `JSONEncoder` with:
- `.outputFormatting = [.prettyPrinted, .sortedKeys]`

History fixtures use `JSONEncoder` with:
- `.dateEncodingStrategy = .iso8601`
- `.outputFormatting = [.prettyPrinted, .sortedKeys]`

Hotkey fields in mode fixtures are set to `null` since `HotkeyConfig`
depends on platform-specific Carbon key codes.

## How Tests Load Fixtures

`FixtureDecodeTests.loadFixture(_:)` reads fixtures from the test bundle
(the immutable copy created at build time). It does NOT read from the
source tree. If a fixture is missing from the bundle, the test fails hard.

## How to Regenerate Mode Fixtures

If `ModeConfig` Codable representation changes, regenerate mode fixtures
from a Swift script or playground:

```swift
import Foundation

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

var config = DefaultModes.dictation()
config.hotkey = nil
let data = try encoder.encode(config)
try data.write(to: URL(fileURLWithPath: "builtin-dictation-vcurrent.json"))
```

Do NOT use a test case for regeneration — tests must validate fixed inputs,
not produce them.

## When to Add New Fixtures

- When the persisted format changes, add a new versioned fixture
  (e.g., `builtin-dictation-v2.json`) and keep the old one to test migration.
- When adding support for older data formats, add representative fixtures
  from those formats.
