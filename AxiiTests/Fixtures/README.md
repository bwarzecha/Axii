# Test Fixtures

Fixture JSON files that capture the current persisted data formats for decode-compatibility testing.

## Structure

- `Modes/` - ModeConfig fixtures for each built-in mode and a sample custom mode.
- `History/Transcription/` - InteractionMetadata and Interaction for a transcription entry.
- `History/Conversation/` - InteractionMetadata and Interaction for a conversation entry.
- `History/Meeting/` - InteractionMetadata and Interaction for a meeting entry.

## Naming Convention

- `builtin-<mode>-vcurrent.json` - Current version of a built-in mode config.
- `custom-sample-vcurrent.json` - Sample custom mode config.
- `metadata.json` / `interaction.json` - Mirror the on-disk history layout.

## Encoding

All JSON was generated to match `JSONEncoder` with:
- `.outputFormatting = [.prettyPrinted, .sortedKeys]`
- `.dateEncodingStrategy = .iso8601`

Hotkey fields in mode fixtures are set to `null` since `HotkeyConfig` depends on platform-specific Carbon key codes.

## Usage

Tests decode these fixtures and verify round-trip compatibility. When the persisted format changes, add a new versioned fixture (e.g., `builtin-dictation-v2.json`) and keep the old one to test migration.
