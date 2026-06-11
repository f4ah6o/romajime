# Romajime

Romajime is a macOS InputMethodKit proof of concept for typing Japanese from romaji.

## Current Phase

Phase 1 is implemented:

- Buffer romaji input in an InputMethodKit controller.
- Convert with Space.
- Cycle candidates with repeated Space.
- Commit with Enter.
- Cancel with Escape.
- Use a rule-based romaji-to-kana core with simple `memory.md` term replacement.

The shared conversion core lives in `RomajimeCore` so later AI conversion and iOS keyboard work can reuse the same state and backend contracts.

## Build and Install (Recommended: Using Justfile)

### Quick Setup

```bash
cd /Users/fu2hito/src/romajime

# Build
just build

# Install to ~/Library/Input Methods
just install

# Configure in System Settings (interactive guide)
just setup

# Verify installation
just test
```

### Manual Setup (Legacy)

```bash
xcodegen generate
xcodebuild test -scheme Romajime -project Romajime.xcodeproj -destination 'platform=macOS'
./script/build_and_run.sh --verify
```

### Available Justfile Recipes

Run `just help` for all available recipes:

- **`just build`** - Compile the project with xcodebuild
- **`just install`** - Copy RomajimeInputMethod.app to ~/Library/Input Methods
- **`just setup`** - Show interactive System Settings configuration steps
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

For manual smoke testing, copy it to `~/Library/Input Methods/`, log out and back in or restart text input services, then enable Romajime in Keyboard settings.

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
