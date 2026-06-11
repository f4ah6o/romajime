# Romajime

Romajime is a macOS InputMethodKit proof of concept for typing Japanese from romaji.

## Current Phase

Phase 1 is implemented:

- Buffer romaji input in an InputMethodKit controller.
- Keep spaces in the composition buffer for long-form romaji drafts.
- Do not do IME-style conversion or candidate cycling while typing.
- Convert and commit the whole buffered draft automatically after typing pauses.
- Ignore Enter while composing, so chat-style Send shortcuts do not become an
  accidental raw commit path.
- Cancel with Escape.
- Use a rule-based romaji-to-kana core with simple `memory.md` term replacement.

The default idle conversion delay is 1.2 seconds. Very fast typing extends that
wait to 1.8 seconds so long-form drafting is less likely to be interrupted.
Romajime does not require Control+Enter or Command+Enter because those keys are
often used as Send shortcuts in chat apps.

The shared conversion core lives in `RomajimeCore` so later AI conversion and iOS keyboard work can reuse the same state and backend contracts.

## Build and Install (Recommended: Using Justfile)

### Prerequisites

- `xcodegen` (`brew install xcodegen`) and `just` (`brew install just`)
- An **Apple Development** signing certificate. Free Apple ID is enough:
  Xcode → Settings → Accounts → add Apple ID → Manage Certificates → '+' → Apple Development.

### Quick Setup

```bash
# Build, sign, install to ~/Library/Input Methods, and register (no reboot needed)
just install

# Then add Romajime manually:
#   System Settings → Keyboard → Input Sources → Edit → '+' → Japanese → Romajime → Add

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

Romajime reads optional term replacements from:

```text
~/Library/Application Support/Romajime/memory.md
```

Each mapping is one line:

```text
mtg -> ミーティング
todo -> TODO
```

Secrets and model registry tokens should not be stored here. Use 1Password Developer Environments or runtime injection for future model-related credentials.
