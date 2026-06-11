# Romajime build and installation recipes

set shell := ["bash", "-c"]

PROJECT_ROOT := justfile_directory()
DERIVED_DATA := PROJECT_ROOT / "DerivedData"
BUILD_APP := DERIVED_DATA / "Build/Products/Debug/RomajimeInputMethod.app"
INSTALL_DIR := "~/Library/Input Methods"
INPUT_METHOD_ID := "com.f12o.inputmethod.Romajime"
SCHEME := "Romajime"
LSREGISTER := "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# Sign the built app with an Apple Development certificate (frameworks first)
@sign: _verify-build
    @identity=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"'); \
    if [ -z "$identity" ]; then \
        echo "✗ Error: No 'Apple Development' signing certificate found"; \
        echo "  Open Xcode → Settings → Accounts → add your Apple ID,"; \
        echo "  then Manage Certificates → '+' → Apple Development"; \
        exit 1; \
    fi; \
    echo "Signing with: $identity"; \
    codesign --force --options runtime --sign "$identity" \
        "{{ BUILD_APP }}/Contents/Frameworks/RomajimeCore.framework/Versions/A"; \
    codesign --force --options runtime --sign "$identity" "{{ BUILD_APP }}"; \
    codesign --verify --deep --strict "{{ BUILD_APP }}"; \
    echo "✓ Signed and verified"

# Install the input method to ~/Library/Input Methods and register it
@install: build sign
    @install_dir="$HOME/Library/Input Methods"; \
    mkdir -p "$install_dir"; \
    pkill -f RomajimeInputMethod 2>/dev/null; \
    rm -rf "$install_dir/RomajimeInputMethod.app"; \
    ditto "{{ BUILD_APP }}" "$install_dir/RomajimeInputMethod.app"; \
    echo "✓ Installed to $install_dir"
    just register

# Register the installed input method with Text Input Services (no reboot needed)
@register: _build-imesetup
    -killall "System Settings" 2>/dev/null
    @app="$HOME/Library/Input Methods/RomajimeInputMethod.app"; \
    if [ ! -d "$app" ]; then \
        echo "✗ Error: not installed — run 'just install' first"; \
        exit 1; \
    fi; \
    {{ LSREGISTER }} -f "$app"; \
    echo "✓ Registered with LaunchServices"
    "{{ PROJECT_ROOT }}/.build/imesetup" refresh
    @echo ""
    @echo "✓ Registration complete"
    @echo ""
    @echo "Add Romajime in: System Settings → Keyboard → Input Sources"
    @echo "  '+' → Japanese → Romajime → Add"

# Verify the input source is visible to the system
@check: _build-imesetup
    "{{ PROJECT_ROOT }}/.build/imesetup" status

# Configure the input method in System Settings (interactive)
@setup: install
    @echo ""
    @echo "Romajime is installed and registered. To enable it:"
    @echo ""
    @echo "1️⃣  Open System Settings → Keyboard → Input Sources → Edit"
    @echo ""
    @echo "2️⃣  Click '+' button to add input method"
    @echo "   • Select 'Japanese'"
    @echo "   • Find and select 'Romajime'"
    @echo "   • Click 'Add'"
    @echo ""
    @echo "3️⃣  Switch to Romajime"
    @echo "   • Control + Space (or ⌘ Space)"
    @echo "   • Or use Input Method menu in menu bar"
    @echo ""
    @echo "4️⃣  Test it out!"
    @echo "   • Open TextEdit or any text editor"
    @echo "   • Run 'just test' for input examples"
    @echo ""
    @echo "If Romajime does not appear in the list, log out and back in."

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
    just check
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
    pkill -f RomajimeInputMethod 2>/dev/null; \
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
    @echo "  sign        - Sign with Apple Development certificate"
    @echo "  install     - Build, sign, install, and register"
    @echo "  register    - Register installed app with Text Input Services"
    @echo "  check       - Verify the input source is visible to the system"
    @echo "  setup       - Install + show System Settings steps"
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
    @echo "  $ just install    # Build, sign, install, and register"
    @echo "  $ just setup      # Same + System Settings guide"
    @echo "  $ just check      # Verify registration"
    @echo "  $ just test       # Verify and show test steps"
    @echo ""
    @echo "Common recipes:"
    @echo "  build           - Build with xcodebuild"
    @echo "  sign            - Sign with Apple Development certificate"
    @echo "  install         - Build, sign, copy, and register"
    @echo "  register        - (Re-)register with Text Input Services"
    @echo "  check           - Verify input source visibility"
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

# Compile the imesetup helper tool when missing or outdated
_build-imesetup:
    @mkdir -p "{{ PROJECT_ROOT }}/.build"; \
    tool="{{ PROJECT_ROOT }}/.build/imesetup"; \
    src="{{ PROJECT_ROOT }}/script/imesetup.swift"; \
    if [ ! -x "$tool" ] || [ "$src" -nt "$tool" ]; then \
        swiftc -O "$src" -o "$tool"; \
        echo "✓ Built imesetup helper"; \
    fi

# Check if xcodegen is installed
_check-xcodegen:
    @if ! command -v xcodegen &> /dev/null; then \
        echo "✗ Error: xcodegen not found"; \
        echo ""; \
        echo "Install with: brew install xcodegen"; \
        exit 1; \
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
