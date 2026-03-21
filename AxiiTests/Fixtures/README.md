# Test Fixtures

Committed JSON files that capture persisted data formats for decode-compatibility testing.

**These files are characterization fixtures. They must not be modified by automated test runs.**

## Fixture Categories

### Current-Format Synthetic Fixtures (`Modes/`, `History/`)

Generated from current code to test the latest Codable format.

- `Modes/builtin-dictation-vcurrent.json` — Dictation mode (hotkey null)
- `Modes/builtin-conversation-vcurrent.json` — Conversation mode (hotkey null)
- `Modes/builtin-meeting-vcurrent.json` — Meeting mode (hotkey null)
- `Modes/custom-sample-vcurrent.json` — Custom mode with processing steps
- `History/Transcription/transcription-metadata.json` — Synthetic transcription metadata
- `History/Transcription/transcription-interaction.json` — Synthetic transcription interaction
- `History/Conversation/conversation-metadata.json` — Synthetic conversation metadata
- `History/Conversation/conversation-interaction.json` — Synthetic conversation interaction
- `History/Meeting/meeting-metadata.json` — Synthetic meeting metadata
- `History/Meeting/meeting-interaction.json` — Synthetic meeting interaction

### Historical Real-World Fixtures (`Legacy/`)

Captured from a live Axii installation (January 2026), anonymized, and
committed. These protect backward compatibility with the on-disk format
that real users have.

**Anonymization applied to all legacy fixtures:**
- All transcription text, conversation messages, and meeting segment text replaced with neutral content
- Preview text replaced
- Window titles replaced
- Bundle identifiers replaced with generic equivalents
- URLs and selected text in focusContext replaced
- App names replaced where they reveal personal context
- Approximate word counts and message counts preserved for structural assertions
- All structural fields, nesting, optional presence/absence, and encoding style preserved exactly

**Mode fixtures:**

| File | Source Date | What It Protects |
|------|-----------|-----------------|
| `legacy-mode-dictation-2026-01.json` | Jan 2026 | Real hotkey present, `"_0"` enum wrapper, pretty-printed |
| `legacy-mode-conversation-2026-01.json` | Jan 2026 | `llmTransform` step with `"_0"` wrapper, `stayOpen` persistence |
| `legacy-mode-meeting-2026-01.json` | Jan 2026 | Compact (non-pretty-printed) JSON, dual capture, streaming config, Float `silenceThreshold` |

**History fixtures:**

| File | Source Date | What It Protects |
|------|-----------|-----------------|
| `legacy-transcription-2026-01-21-no-focuscontext-*` | Jan 21 2026 | Transcription before `focusContext` was added. `focusContext` field absent. WAV audio at 48kHz. |
| `legacy-transcription-2026-01-26-with-focuscontext-*` | Jan 26 2026 | Transcription after `focusContext`. `surroundingText` with `selected` text. WAV audio at 24kHz. |
| `legacy-conversation-2026-01-23-*` | Jan 23 2026 | Early conversation. Empty `audioRecordings` array. 2 messages. `updatedAt` > `createdAt`. |
| `legacy-meeting-2026-01-28-*` | Jan 28 2026 | Early meeting. 4 segments (2 mic + 2 system). Both WAV recordings at 16kHz. Fractional duration. |

## Naming Convention

Filenames must be globally unique because Xcode flattens subdirectories
when copying resources into the test bundle.

- Current fixtures: `builtin-<mode>-vcurrent.json`, `<type>-metadata.json`
- Legacy fixtures: `legacy-<type>-<date>-<variant>.json`

## How Tests Load Fixtures

`loadFixture(_:)` reads fixtures from the test bundle (immutable copy
created at build time). It does NOT read from the source tree.
If a fixture is missing from the bundle, the test fails hard.

## How to Regenerate Mode Fixtures

If `ModeConfig` Codable representation changes, regenerate current-format
mode fixtures from a Swift script or playground:

```swift
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

var config = DefaultModes.dictation()
config.hotkey = nil
let data = try encoder.encode(config)
try data.write(to: URL(fileURLWithPath: "builtin-dictation-vcurrent.json"))
```

Do NOT use a test case for regeneration — tests must validate fixed inputs,
not produce them.

**Never regenerate legacy fixtures.** They capture historical formats and
must remain exactly as committed.

## When to Add New Fixtures

- When the persisted format changes, add a new versioned fixture
  (e.g., `builtin-dictation-v2.json`) and keep the old one to test migration.
- When supporting older data formats, add representative historical fixtures.
- When adding a fixture from real user data, anonymize aggressively per
  the process documented above.

## Test Design Principles

**Fixture decode tests** are compatibility/contract tests. They verify that
committed JSON decodes into the expected model types with the expected
field values. They should never mutate fixtures or depend on runtime state.

**Integration tests** should prefer public behavioral contracts over
implementation details:
- Assert on persisted outcomes (files on disk, loadable interactions)
- Assert on observable state (phase, finalText, needsManualCopy)
- Assert via public APIs (listMetadata, loadInteraction, getAudioURL)
- Avoid asserting on internal caches, helper objects, or scheduling
  internals unless there is no public observable for the contract

**Characterization tests** (e.g., dictation orchestration) may temporarily
access internals where the current architecture makes it unavoidable.
These are marked with inline `NOTE` comments explaining:
- what behavioral contract they protect
- why no public observable exists yet
- when they should be replaced (typically during coordinator extraction)

Future refactors should replace internal-touching tests with seam-based
contract tests rather than re-entrenching the coupling.
