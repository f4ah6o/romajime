<p align="center">
  <img src="docs/assets/romajime-logo.png" alt="romajime logo" width="160">
</p>

# romajime

romajime is a macOS InputMethodKit proof of concept for typing Japanese from romaji.

The Japanese README is available at [README.md](README.md).

## Current Phase

Phase 1 is implemented:

- Buffer romaji input in an InputMethodKit controller.
- Keep spaces in the composition buffer for long-form romaji drafts.
- Do not do IME-style conversion or candidate cycling while typing.
- Convert and commit the whole buffered draft automatically after typing pauses.
- Keep Return and keypad Enter as newlines in the composition buffer by default.
- Enter can still be configured as ignored, so chat-style Send shortcuts do not
  become an accidental raw commit path.
- Convert and commit immediately with Escape while composing.
- Start phrase jump mode with Escape while not composing. Jump labels accept
  alphabetic labels or numeric aliases in reading order; type the label, then
  press Space to jump.
- Use a rule-based romaji-to-kana core with simple `memory.md` term replacement.
- Convert kana drafts to kanji with the on-device Foundation Models when
  available; fall back to the kana result on timeout, error, or older macOS.
  The model is prewarmed when composition starts so long-form drafts usually
  convert without waiting for the model load.
- Focus loss or input-source switch commits the kana result synchronously
  because the OS expects the composition resolved before returning.
- The marked text now carries proper TSM hilite attributes so the caret stays
  at the end of the composition buffer across clients.

The default idle conversion delay is 1.2 seconds. Very fast typing extends that
wait to 1.8 seconds so long-form drafting is less likely to be interrupted.
romajime does not require Control+Enter or Command+Enter because those keys are
often used as Send shortcuts in chat apps.

Jump mode reads nearby text from the active `IMKTextInput`, groups it into
larger phrases using punctuation and newlines rather than every whitespace
separated word, then moves the insertion point to the chosen phrase when Space
confirms the typed label. Alphabet labels run `a` through `z`, then `aa`, `ab`,
and so on; numeric aliases run `1`, `2`, `3`, and so on. Jump mode cancels after
3 seconds of inactivity. Each visible jump target gets a short-lived link-like
label badge near the phrase start. If the client app does not provide character
position rectangles, romajime skips only the badge overlay and keeps keyboard
jumping available.

The shared conversion core lives in `RomajimeCore` so later AI conversion and iOS keyboard work can reuse the same state and backend contracts.

## Configuration

romajime reads optional configuration from:

```text
~/Library/Application Support/Romajime/config.json
```

If the file is missing or invalid, romajime uses the defaults below. Text input
keys are not configurable; only non-input control keys and timings are.

```json
{
  "keyBindings": {
    "bufferSpace": { "keyCode": 49 },
    "newlineCommit": [{ "keyCode": 36 }, { "keyCode": 76 }],
    "ignoredCommit": [],
    "deleteBackward": { "keyCode": 51 },
    "convertOrJump": { "keyCode": 53 },
    "jumpConfirm": { "keyCode": 49 },
    "jumpCancel": { "keyCode": 53 }
  },
  "timing": {
    "idleBaseDelay": 1.2,
    "idleFastTypingDelay": 1.8,
    "idleFastTypingThreshold": 0.18,
    "idleSentenceBoundaryDelay": 0.45,
    "maxComposingDelay": 8.0,
    "localIntelligenceEnabled": true,
    "localIntelligenceTimeout": 0.3,
    "kanjiConversionEnabled": true,
    "kanjiConversionTimeout": 2.0,
    "jumpModeTimeout": 3.0
  }
}
```

Default key codes are: Space `49`, Return `36`, keypad Enter `76`, Delete `51`,
Escape `53`. Add `"requiredModifiers"` when a binding should only match an
exact modifier mask.

To restore the old Enter behavior, set `"newlineCommit": []` and
`"ignoredCommit": [{ "keyCode": 36 }, { "keyCode": 76 }]`.

## Build and Install (Recommended: Using Justfile)

### Prerequisites

- macOS 26 SDK or later.
- `xcodegen` (`brew install xcodegen`) and `just` (`brew install just`)
- An **Apple Development** signing certificate. Free Apple ID is enough:
  Xcode → Settings → Accounts → add Apple ID → Manage Certificates → '+' → Apple Development.

### Quick Setup

```bash
# Build, sign, install to ~/Library/Input Methods, and register (no reboot needed)
just install

# Then add romajime manually:
#   System Settings → Keyboard → Input Sources → Edit → '+' → Japanese → romajime → Add

# Verify registration / show test steps
just check
just test
```

### Available Justfile Recipes

Run `just help` for all available recipes:

- **`just build`** - Compile the project with xcodebuild
- **`just sign`** - Sign with your Apple Development certificate
- **`just install`** - Build, sign, copy to ~/Library/Input Methods, and register
- **`just register`** - (Re-)register the installed app with Text Input Services
- **`just check`** - Verify the input source is visible to the system
- **`just setup`** - Install + show System Settings configuration steps
- **`just test`** - Display manual testing instructions
- **`just dev-run`** - Launch the app directly (for development)
- **`just clean`** - Remove build artifacts
- **`just uninstall`** - Remove the input method from ~/Library/Input Methods
- **`just test-unit`** - Run RomajimeCoreTests
- **`just info`** - Show build configuration

## Input Method Bundle

The debug input method app is produced at:

```text
DerivedData/Build/Products/Debug/RomajimeInputMethod.app
```

## macOS Registration Notes (Hard-Won Knowledge)

Getting a development-signed IME to appear in System Settings on macOS 26
required all of the following — `just install` handles every step:

1. **Bundle ID must contain `.inputmethod.` as an inner component.**
   `com.f12o.inputmethod.Romajime` works; `com.f12o.Romajime.inputmethod`
   (trailing component) is silently ignored by the input source scan.
   All real IMEs follow this shape: `com.justsystems.inputmethod.atok35`,
   `dev.ensan.inputmethod.azooKeyMac`, `com.apple.inputmethod.Kotoeri`.
2. **`ENABLE_DEBUG_DYLIB: NO`.** Xcode debug builds otherwise produce a stub
   executable plus `*.debug.dylib`, which breaks the IME bundle.
3. **A valid code signature.** Ad-hoc builds with `CODE_SIGNING_ALLOWED: NO`
   leave a broken signature. Sign frameworks first, then the app
   (`codesign --force --options runtime --sign "Apple Development: ..."`).
4. **Copy with `ditto`, not `cp -r`** — `cp` flattens the framework symlink
   structure and invalidates the signature.
5. **Rebuild the per-user input source cache atomically.** The cache lives at
   `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.IntlDataCache.le*`. Stale caches
   hide new IMEs. The deletion and the rescan must happen inside one process
   (`script/imesetup.swift refresh`): if a sandboxed process rebuilds the cache
   first, it cannot read `~/Library/Input Methods` and writes a cache without
   user IMEs.
6. **Never call `TISRegisterInputSource` / `TISEnableInputSource`** from a
   helper on macOS 26 — both write back a store that drops user-installed
   bundles for other processes. Let the directory scan discover the bundle and
   let the user enable it in System Settings.

## Memory

romajime reads optional term replacements from:

```text
~/Library/Application Support/Romajime/memory.md
```

Each mapping is one line:

```text
mtg -> ミーティング
todo -> TODO
```

Secrets and model registry tokens should not be stored here. Use 1Password Developer Environments or runtime injection for future model-related credentials.
