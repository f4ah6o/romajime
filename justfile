# Romajime build and installation recipes

set shell := ["bash", "-c"]

PROJECT_ROOT := justfile_directory()
DERIVED_DATA := PROJECT_ROOT / "DerivedData"
BUILD_APP := DERIVED_DATA / "Build/Products/Debug/RomajimeInputMethod.app"
INSTALL_DIR := "~/Library/Input Methods"
INPUT_METHOD_ID := "com.f12o.Romajime.inputmethod"
SCHEME := "Romajime"

# Build the Romajime input method with xcodebuild
@build: _check-xcodegen
    if [ ! -d "{{ PROJECT_ROOT }}/Romajime.xcodeproj" ]; then \
        xcodegen generate; \
    fi
    xcodebuild \
        -scheme {{ SCHEME }} \
        -project {{ PROJECT_ROOT }}/Romajime.xcodeproj \
        -configuration Debug \
        -derivedDataPath {{ DERIVED_DATA }} \
        build
    @echo "✓ Build successful"
    @echo "  Output: {{ BUILD_APP }}"

# Install the input method to ~/Library/Input Methods
@install: build
    @if [ ! -d "{{ BUILD_APP }}" ]; then \
        echo "Error: Build artifact not found at {{ BUILD_APP }}"; \
        exit 1; \
    fi
    @install_dir="$HOME/Library/Input Methods"; \
    if [ ! -d "$install_dir" ]; then \
        mkdir -p "$install_dir"; \
        echo "ℹ Created $install_dir"; \
    fi; \
    if [ -d "$install_dir/RomajimeInputMethod.app" ]; then \
        rm -rf "$install_dir/RomajimeInputMethod.app"; \
        echo "  (Removed existing installation)"; \
    fi; \
    cp -r "{{ BUILD_APP }}" "$install_dir/"; \
    echo "✓ Installed to $install_dir"; \
    echo ""; \
    echo "⚠ Next steps:"; \
    echo "  1. Log out and back in (or restart)"; \
    echo "  2. Run: just setup"

# Configure the input method in System Settings (interactive)
@setup: install
    @echo "Setting up Romajime input method..."
    @echo ""
    @echo "⚠ IMPORTANT: System Restart Required"
    @echo ""
    @echo "macOS needs to restart input method services to recognize Romajime."
    @echo ""
    @echo "1️⃣  RESTART YOUR MAC"
    @echo "   • Apple menu → Shut Down → check 'Reopen windows when logging back in'"
    @echo "   • Or: ⌘ + Control + Eject"
    @echo ""
    @echo "2️⃣  After restart, open System Settings"
    @echo "   Keyboard → Input Sources"
    @echo ""
    @echo "3️⃣  Click '+' button to add input method"
    @echo "   • Select 'Japanese'"
    @echo "   • Find and select 'Romajime'"
    @echo "   • Click 'Add'"
    @echo ""
    @echo "4️⃣  Switch to Romajime"
    @echo "   • Control + Space (or ⌘ Space)"
    @echo "   • Or use Input Method menu in menu bar"
    @echo ""
    @echo "5️⃣  Test it out!"
    @echo "   • Open TextEdit or any text editor"
    @echo "   • Run 'just test' for input examples"
    @echo ""

# Test the installation
@test:
    @echo "Testing Romajime installation..."
    @echo ""
    @install_dir="$HOME/Library/Input Methods"; \
    if [ ! -d "$install_dir/RomajimeInputMethod.app" ]; then \
        echo "✗ Error: RomajimeInputMethod.app not found in $install_dir"; \
        echo "  Did you run 'just install'?"; \
        exit 1; \
    else \
        echo "✓ RomajimeInputMethod.app found in $install_dir"; \
    fi
    @echo ""
    @echo "Manual test steps:"
    @echo ""
    @echo "  1. Open any text editor (TextEdit, VSCode, etc.)"
    @echo "  2. Switch input method to 'Romajime'"
    @echo "  3. Type the following and test:"
    @echo ""
    @echo "     Input          → Expected Output"
    @echo "     ─────────────────────────────────"
    @echo "     a              → あ"
    @echo "     ka             → か"
    @echo "     nihongo        → [にほんご候補]"
    @echo "     (Space)        → cycle candidates"
    @echo "     (Enter)        → commit selection"
    @echo "     (Escape)       → cancel input"
    @echo ""

# Run the app in development mode (not as input method)
@dev-run: build _verify-build
    pkill -x Romajime 2>/dev/null || true
    open -n "{{ BUILD_APP }}"
    @echo "✓ Launched Romajime (development mode)"

# Clean build artifacts
@clean:
    @if [ -d "{{ DERIVED_DATA }}" ]; then \
        rm -rf "{{ DERIVED_DATA }}"; \
        echo "✓ Cleaned DerivedData"; \
    fi
    @if [ -d "{{ PROJECT_ROOT }}/build" ]; then \
        rm -rf "{{ PROJECT_ROOT }}/build"; \
        echo "✓ Cleaned build/"; \
    fi

# Uninstall the input method
@uninstall:
    @install_dir="$HOME/Library/Input Methods"; \
    if [ -d "$install_dir/RomajimeInputMethod.app" ]; then \
        rm -rf "$install_dir/RomajimeInputMethod.app"; \
        echo "✓ Uninstalled from $install_dir"; \
    else \
        echo "ℹ RomajimeInputMethod.app not found in $install_dir"; \
    fi
    @echo ""
    @echo "To remove from System Settings:"
    @echo "  1. Open System Settings"
    @echo "  2. Keyboard → Input Sources"
    @echo "  3. Find 'Romajime' and click '-' button"

# Run unit tests
@test-unit:
    @echo "Running RomajimeCoreTests..."
    xcodebuild test \
        -scheme {{ SCHEME }} \
        -project {{ PROJECT_ROOT }}/Romajime.xcodeproj \
        -destination 'platform=macOS'

# Display project configuration
@info:
    @echo "Romajime Build Configuration:"
    @echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    @echo "  Project Root:    {{ PROJECT_ROOT }}"
    @echo "  Derived Data:    {{ DERIVED_DATA }}"
    @echo "  Build Target:    {{ BUILD_APP }}"
    @echo "  Install Dir:     {{ INSTALL_DIR }}"
    @echo "  Scheme:          {{ SCHEME }}"
    @echo "  Bundle ID:       {{ INPUT_METHOD_ID }}"
    @echo ""
    @echo "Recipes:"
    @echo "  build       - Build the input method"
    @echo "  install     - Install to ~/Library/Input Methods"
    @echo "  setup       - Configure in System Settings (interactive)"
    @echo "  test        - Show installation test steps"
    @echo "  dev-run     - Launch app in development mode"
    @echo "  clean       - Remove build artifacts"
    @echo "  uninstall   - Remove from ~/Library/Input Methods"
    @echo "  test-unit   - Run unit tests"
    @echo "  info        - Show this configuration"
    @echo "  help        - Show all recipes"

# Show available recipes
@help:
    @echo "Romajime Setup Recipes"
    @echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    @echo ""
    @echo "Quick start:"
    @echo "  $ just build      # Compile the project"
    @echo "  $ just install    # Install to ~/Library/Input Methods"
    @echo "  $ just setup      # Configure in System Settings"
    @echo "  $ just test       # Verify and test"
    @echo ""
    @echo "Common recipes:"
    @echo "  build           - Build with xcodebuild"
    @echo "  install         - Copy app to ~/Library/Input Methods"
    @echo "  setup           - Show System Settings configuration steps"
    @echo "  test            - Show manual testing steps"
    @echo "  dev-run         - Launch app directly (development)"
    @echo "  clean           - Remove DerivedData and build/"
    @echo "  uninstall       - Remove app from ~/Library/Input Methods"
    @echo ""
    @echo "Advanced recipes:"
    @echo "  test-unit       - Run RomajimeCoreTests"
    @echo "  info            - Show build configuration"
    @echo "  help            - Show this message"
    @echo ""

# ────────────────────────────────────────────────────────────
# Helper recipes (private, prefixed with underscore)
# ────────────────────────────────────────────────────────────

# Check if xcodegen is installed
_check-xcodegen:
    @if ! command -v xcodegen &> /dev/null; then \
        echo "✗ Error: xcodegen not found"; \
        echo ""; \
        echo "Install with: brew install xcodegen"; \
        exit 1; \
    fi

# Check and create input method install directory
_check-install-target:
    @if [ ! -d ~/Library/Input\ Methods ]; then \
        mkdir -p ~/Library/Input\ Methods; \
        echo "ℹ Created ~/Library/Input Methods"; \
    fi

# Verify build artifact exists
_verify-build:
    @if [ ! -d "{{ BUILD_APP }}" ]; then \
        echo "✗ Error: Build artifact not found"; \
        echo "  Expected: {{ BUILD_APP }}"; \
        echo ""; \
        echo "Run 'just build' first"; \
        exit 1; \
    fi
