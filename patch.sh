#!/bin/bash
# ============================================================================
#
#   ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗   ██████╗ ████████╗██╗
#  ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝   ██╔══██╗╚══██╔══╝██║
#  ██║     ██║     ███████║██║   ██║██║  ██║█████╗     ██████╔╝   ██║   ██║
#  ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝     ██╔══██╗   ██║   ██║
#  ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗   ██║  ██║   ██║   ███████╗
#   ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝   ╚═╝  ╚═╝   ╚═╝   ╚══════╝
#
#   Claude Desktop RTL Patcher for macOS
#   Adds right-to-left (Hebrew / Arabic / Persian) support to Claude Desktop
#   by patching a *copy* of the app — the original is never touched.
#
#   Run with --help for usage, or --dry-run to preview without changing anything.
# ============================================================================

set -euo pipefail

VERSION="2.0.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_FILE="$SCRIPT_DIR/rtl-payload.js"
ICON_FILE="$SCRIPT_DIR/icon.icns"
FONTS_DIR="$SCRIPT_DIR/fonts"

# Font used for RTL (Hebrew/Arabic/Persian) text. Disabled by default — RTL
# text keeps Claude's default font. Opt in either way:
#   * Command line:  ./patch.sh --install --font Vazirmatn (or Estedad)
#   * Environment:   RTL_FONT_FAMILY=Vazirmatn ./patch.sh --install
# Vazirmatn and Estedad (Persian/Arabic, OFL) are bundled in fonts/ — pass
# --font Vazirmatn or --font Estedad to embed them. To use a different font,
# drop your own .woff2/.woff/.ttf/.otf files in fonts/ and pass --font
# "<family-name>" (the embedded files mean it works even if the font isn't
# installed on the system). With no matching files in fonts/ the patch falls
# back to an already-installed font of that name.
# The --font flag overrides RTL_FONT_FAMILY when both are set.
RTL_FONT_FAMILY="${RTL_FONT_FAMILY-}"

SOURCE_APP="/Applications/Claude.app"
SOURCE_ASAR="$SOURCE_APP/Contents/Resources/app.asar"
PATCHED_APP="$HOME/Applications/Claude-RTL.app"
PATCHED_ASAR="$PATCHED_APP/Contents/Resources/app.asar"

TMP_DIR=""

# Runtime modes (set by the argument parser, see Main).
DRY_RUN=false       # --dry-run / -n : preview only, never mutate anything
COLOR_MODE=auto     # auto | always | never
ASSUME_YES=false    # --yes / -y : skip the interactive menu confirmation
DEPS_OK=true        # set by check_dependencies

# Per-action step counter (cosmetic "[n/total]" progress labels).
STEP=0
STEP_TOTAL=0

# ---------------------------------------------------------------------------
# Colors & symbols
# ---------------------------------------------------------------------------
# Colors are resolved *after* argument parsing so --color/--no-color and the
# NO_COLOR convention can take effect. Until then they are empty (no-ops).
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' DIM='' BOLD='' NC=''

setup_colors() {
    local enable=false
    case "$COLOR_MODE" in
        always) enable=true ;;
        never)  enable=false ;;
        auto)
            # Enable only on a real terminal, honoring the NO_COLOR convention.
            if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
                enable=true
            fi
            ;;
    esac

    if $enable; then
        RED=$'\033[0;31m';   GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
        BLUE=$'\033[0;34m';  CYAN=$'\033[0;36m';  MAGENTA=$'\033[0;35m'
        DIM=$'\033[2m';      BOLD=$'\033[1m';     NC=$'\033[0m'
    fi
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()     { printf '   %s•%s %s\n'  "$DIM"     "$NC" "$1"; }
success() { printf '   %s✓%s %s\n'  "$GREEN"   "$NC" "$1"; }
warn()    { printf '   %s▲%s %s\n'  "$YELLOW"  "$NC" "$1"; }
err()     { printf '   %s✗%s %s\n'  "$RED"     "$NC" "$1" >&2; }
info()    { printf '   %sℹ%s %s\n'  "$BLUE"    "$NC" "$1"; }
dry()     { printf '   %s◌%s %s%swould%s %s\n' "$MAGENTA" "$NC" "$DIM" "$MAGENTA" "$NC" "$1"; }

# A numbered "step" heading. STEP_TOTAL is set by each action up front.
step() {
    STEP=$((STEP + 1))
    printf '\n%s  ▸ %s%s  %s[%d/%d]%s\n' "$BOLD$CYAN" "$1" "$NC" "$DIM" "$STEP" "$STEP_TOTAL" "$NC"
}

hr() { printf '%s  ────────────────────────────────────────────────────────%s\n' "$DIM" "$NC"; }

# A tidy framed banner. Drawn in a single color so embedded escape codes never
# throw off the box alignment.
banner() {
    local title="$1" subtitle="${2:-}"
    printf '\n%s' "$BOLD$CYAN"
    printf '  ╭──────────────────────────────────────────────────────╮\n'
    printf '  │  %-52s│\n' "$title"
    if [ -n "$subtitle" ]; then
        printf '  │  %-52s│\n' "$subtitle"
    fi
    printf '  ╰──────────────────────────────────────────────────────╯'
    printf '%s\n' "$NC"
}

# Run a simple command, or just describe it in dry-run mode.
run() {
    if $DRY_RUN; then dry "$*"; return 0; fi
    "$@"
}

die() { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependency helpers
# ---------------------------------------------------------------------------
asar_cmd() {
    if command -v asar &>/dev/null; then
        asar "$@"
    elif command -v npx &>/dev/null; then
        npx --yes @electron/asar "$@"
    else
        die "Bug: asar_cmd called without asar or npx available."
    fi
}

fuses_cmd() {
    if command -v npx &>/dev/null; then
        npx --yes @electron/fuses "$@"
    else
        die "Bug: fuses_cmd called without npx available."
    fi
}

# Populates DEPS_OK. In normal runs a missing dependency is fatal; in dry-run
# we only warn so the user can still preview the high-level plan.
check_dependencies() {
    local missing=()

    if ! command -v npx &>/dev/null && ! command -v asar &>/dev/null; then
        missing+=("Node.js (provides npx) or @electron/asar (npm install -g @electron/asar)")
    fi

    if ! command -v npx &>/dev/null; then
        missing+=("Node.js (provides npx, needed for @electron/fuses)")
    fi

    if ! command -v codesign &>/dev/null; then
        missing+=("Xcode Command Line Tools (provides codesign)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        DEPS_OK=false
        err "Missing required dependencies:"
        local dep
        for dep in "${missing[@]}"; do
            printf '       %s-%s %s\n' "$RED" "$NC" "$dep"
        done
        echo ""
        echo "    Install Node.js:        https://nodejs.org/ or 'brew install node'"
        echo "    Install Xcode CLI tools: xcode-select --install"
        echo ""
        if ! $DRY_RUN; then
            exit 1
        fi
        warn "Continuing in dry-run with a reduced preview (file-level steps skipped)."
    else
        DEPS_OK=true
    fi
}

# ---------------------------------------------------------------------------
# Claude process management
# ---------------------------------------------------------------------------
quit_claude_rtl() {
    # Only quit the patched RTL copy, not the original Claude or Claude Code.
    if pgrep -f "Claude-RTL.app" &>/dev/null; then
        if $DRY_RUN; then
            dry "quit the running Claude-RTL.app"
            return 0
        fi
        log "Quitting the running Claude-RTL..."
        # Use the bundle identifier approach to be precise.
        osascript -e 'tell application "Claude-RTL" to quit' 2>/dev/null || true
        sleep 2
        # If still running, force kill only the exact process.
        pkill -f "Claude-RTL.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
        success "Claude-RTL stopped."
    fi
}

# ---------------------------------------------------------------------------
# Font injector
# ---------------------------------------------------------------------------
# Appends a self-contained IIFE to the given header file that (a) embeds any
# font files in fonts/ as @font-face rules under $RTL_FONT_FAMILY, and (b)
# applies that family to RTL-detected text (keeping code monospace). The font
# is the user's choice: replace the files in fonts/ and/or set RTL_FONT_FAMILY.
# All CSS uses single quotes so it embeds safely in a double-quoted JS string.
build_font_injector() {
    local header="$1"

    # Sanitize the family name: strip characters that would break the CSS/JS string.
    local family="${RTL_FONT_FAMILY//\"/}"
    family="${family//\\/}"
    family="${family//\'/}"

    if [ -z "$family" ]; then
        log "Font: ${BOLD}none${NC} (default) — RTL text keeps Claude's font. Use --font NAME to opt in."
        return 0
    fi

    # Embed each font file in fonts/ as an @font-face for "$family". Weight and
    # style are guessed from the filename (e.g. "...-Bold", "...-Light-Italic").
    local face_css=""
    local embedded=0
    if [ -d "$FONTS_DIR" ]; then
        shopt -s nullglob nocaseglob
        local f
        for f in "$FONTS_DIR"/"$family"*.woff2 "$FONTS_DIR"/"$family"*.woff "$FONTS_DIR"/"$family"*.ttf "$FONTS_DIR"/"$family"*.otf; do
            [ -f "$f" ] || continue
            local lc weight style ext fmt mime b64
            lc=$(basename "$f" | tr '[:upper:]' '[:lower:]')

            weight=400
            case "$lc" in
                *thin*)                    weight=100 ;;
                *extralight*|*ultralight*) weight=200 ;;
                *light*)                   weight=300 ;;
                *medium*)                  weight=500 ;;
                *semibold*|*demibold*)     weight=600 ;;
                *extrabold*|*ultrabold*)   weight=800 ;;
                *black*|*heavy*)           weight=900 ;;
                *bold*)                    weight=700 ;;
            esac

            style=normal
            case "$lc" in *italic*|*oblique*) style=italic ;; esac

            ext="${lc##*.}"
            case "$ext" in
                woff2) fmt=woff2;    mime="font/woff2" ;;
                woff)  fmt=woff;     mime="font/woff" ;;
                ttf)   fmt=truetype; mime="font/ttf" ;;
                otf)   fmt=opentype; mime="font/otf" ;;
                *) continue ;;
            esac

            b64=$(base64 < "$f" | tr -d '\n')
            face_css+="@font-face{font-family:'${family}';font-style:${style};font-weight:${weight};font-display:swap;src:url(data:${mime};base64,${b64}) format('${fmt}');}"
            embedded=$((embedded + 1))
            log "  ${DIM}embed${NC} $(basename "$f") ${DIM}→ weight ${weight}, ${style}${NC}"
        done
        shopt -u nullglob nocaseglob
    fi

    # Apply the family to RTL text. Fallbacks cover Hebrew/Latin glyphs the
    # chosen font may lack; code stays monospace. (Selectors use single quotes.)
    face_css+="[dir='rtl'],[dir='rtl'] *,[data-testid='chat-input'],.tiptap.ProseMirror{font-family:'${family}',Tahoma,-apple-system,system-ui,sans-serif!important}"
    face_css+="[dir='rtl'] pre,[dir='rtl'] code,[dir='rtl'] pre *,[dir='rtl'] code *,.tiptap.ProseMirror pre,.tiptap.ProseMirror code,.tiptap.ProseMirror pre *,.tiptap.ProseMirror code *{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace!important}"

    {
        printf '\n// --- CLAUDE RTL FONT START ---\n'
        printf ';(function(){if(typeof document==="undefined")return;function add(){if(document.getElementById("claude-rtl-font"))return;if(!document.head&&!document.documentElement)return;var s=document.createElement("style");s.id="claude-rtl-font";s.textContent="%s";(document.head||document.documentElement).appendChild(s);}if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",add);}else{add();}})();\n' "$face_css"
        printf '// --- CLAUDE RTL FONT END ---\n'
    } >> "$header"

    if [ "$embedded" -gt 0 ]; then
        success "Font: ${BOLD}$family${NC} — embedded $embedded file(s) from fonts/ as base64 data: URIs."
    else
        warn "Font: ${BOLD}$family${NC} — no files in fonts/, relying on an installed font of that name."
    fi
}

# ---------------------------------------------------------------------------
# Injection (shared by install + dry-run preview)
# ---------------------------------------------------------------------------
# Prepends $header to every renderer .js under <app_dir>/.vite/build, skipping
# the Electron main-process entry and any already-patched file. In dry-run mode
# it reports what *would* happen without modifying anything. Sets INJECTED and
# SKIPPED for the caller.
inject_payload() {
    local app_dir="$1" header="$2"
    local build_dir="$app_dir/.vite/build"

    if [ ! -d "$build_dir" ]; then
        die ".vite/build/ not found in extracted ASAR. Claude Desktop may have changed its internal structure."
    fi

    # Detect Electron's main-process entry from package.json ("main" field).
    # The RTL payload is a renderer-side script: prepending it to the main
    # process file causes Electron to fail to spawn any BrowserWindow at
    # startup (black screen / silent crash). As of Claude Desktop 1.9255.2
    # the entry is ".vite/build/index.pre.js"; reading it from package.json
    # keeps the patcher forward-compatible if Anthropic renames it.
    # node is guaranteed to be present here — check_dependencies requires npx,
    # which only ships with node.
    local main_basename=""
    if [ -f "$app_dir/package.json" ]; then
        local main_entry
        main_entry=$(node -p "require('$app_dir/package.json').main || ''" 2>/dev/null || echo "")
        if [ -z "$main_entry" ]; then
            die "Could not read \"main\" field from $app_dir/package.json. Claude Desktop's package layout may have changed."
        fi
        main_basename=$(basename "$main_entry")
    fi

    INJECTED=0
    SKIPPED=0
    local js_file name
    for js_file in "$build_dir"/*.js; do
        [ -f "$js_file" ] || continue
        name=$(basename "$js_file")

        # Skip the Electron main-process entry — injecting there crashes startup.
        if [ -n "$main_basename" ] && [ "$name" = "$main_basename" ]; then
            log "skip ${DIM}$name${NC} (Electron main process)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Skip already-patched files (idempotent).
        if grep -q "CLAUDE RTL PATCH START" "$js_file" 2>/dev/null; then
            log "skip ${DIM}$name${NC} (already patched)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        if $DRY_RUN; then
            dry "inject RTL header into ${BOLD}$name${NC}"
        else
            # Prepend the combined header (RTL payload + font) to each JS file.
            cat "$header" "$js_file" > "$app_dir/.rtl-merged.js"
            mv "$app_dir/.rtl-merged.js" "$js_file"
            log "inject ${GREEN}→${NC} $name"
        fi
        INJECTED=$((INJECTED + 1))
    done

    if [ "$INJECTED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
        die "No .js files found in .vite/build/. Claude Desktop structure may have changed."
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_patch() {
    SECONDS=0
    STEP=0; STEP_TOTAL=10

    if $DRY_RUN; then
        banner "Claude Desktop RTL Patcher — Install" "DRY RUN · nothing will be modified"
    else
        banner "Claude Desktop RTL Patcher — Install" "v$VERSION"
    fi

    # --- Preflight ---
    [ ! -d "$SOURCE_APP" ] && die "Claude.app not found at $SOURCE_APP. Is Claude Desktop installed?"
    [ ! -f "$PAYLOAD_FILE" ] && die "rtl-payload.js not found at $PAYLOAD_FILE. Re-clone the repository."

    check_dependencies
    quit_claude_rtl

    # --- 1. Copy ---
    step "Creating patched copy"
    run mkdir -p "$HOME/Applications"
    if [ -d "$PATCHED_APP" ]; then
        log "Removing previous patched copy..."
        run rm -rf "$PATCHED_APP"
    fi
    log "Copying Claude.app → Claude-RTL.app (this may take a moment)..."
    run cp -R "$SOURCE_APP" "$PATCHED_APP"
    $DRY_RUN || success "Created $PATCHED_APP"

    # --- 2. Replace icon ---
    step "Replacing app icon"
    if [ -f "$ICON_FILE" ]; then
        run cp "$ICON_FILE" "$PATCHED_APP/Contents/Resources/electron.icns"
        # macOS prefers CFBundleIconName (asset catalog) over CFBundleIconFile (icns).
        # Remove CFBundleIconName so our custom .icns is used instead.
        if $DRY_RUN; then
            dry "delete CFBundleIconName from Info.plist (so the custom .icns wins)"
        else
            /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || true
            success "Icon replaced with RTL-badged version."
        fi
    else
        warn "icon.icns not found — keeping the original icon."
    fi

    # --- 3. Rename app in Dock / window title ---
    step "Renaming app to Claude-RTL"
    # Use CFBundleDisplayName (cosmetic only) — changing CFBundleName breaks Electron's fuse lookup.
    if $DRY_RUN; then
        dry "set CFBundleDisplayName = Claude-RTL in Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude-RTL" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Claude-RTL" "$PATCHED_APP/Contents/Info.plist"
        success "App will show as \"Claude-RTL\" in Dock and Finder."
    fi

    # --- 4. Extract ASAR ---
    # In dry-run we read the *source* ASAR (read-only) so the preview reflects
    # the real bundle; in a normal run we work on the patched copy's ASAR.
    step "Extracting app.asar"
    if $DRY_RUN && ! $DEPS_OK; then
        warn "asar unavailable — skipping the file-level preview."
    else
        TMP_DIR=$(mktemp -d)
        local extract_from
        if $DRY_RUN; then extract_from="$SOURCE_ASAR"; else extract_from="$PATCHED_ASAR"; fi
        asar_cmd extract "$extract_from" "$TMP_DIR/app"
        success "Extracted$($DRY_RUN && echo ' (read-only, from the original)')."
    fi

    # --- 5. Build the combined header (RTL JS + Font @font-face) ---
    # The font is embedded as a base64 data: URI rather than loaded from a CDN
    # or a local file: Claude's CSP is "font-src 'self' data:" in the main window
    # and "font-src data:" in the artifact preview sandbox, with connect-src 'none'
    # — so external hosts are blocked and only data: URIs work in every context.
    step "Building RTL + font header"
    local header_file=""
    if [ -n "$TMP_DIR" ]; then
        header_file="$TMP_DIR/rtl-header.js"
        cp "$PAYLOAD_FILE" "$header_file"
        build_font_injector "$header_file"
    else
        # No temp dir (dry-run without deps) — still report what the font step would do.
        build_font_injector /dev/null
    fi

    # --- 6. Inject RTL JS ---
    step "Injecting RTL code"
    if [ -n "$TMP_DIR" ] && [ -n "$header_file" ]; then
        inject_payload "$TMP_DIR/app" "$header_file"
        [ "${INJECTED:-0}" -gt 0 ] && success "${INJECTED} file(s) would receive the RTL header."
        [ "${SKIPPED:-0}" -gt 0 ]  && log "${SKIPPED} file(s) skipped (main process / already patched)."
    else
        dry "inject the RTL header into every renderer .js under .vite/build/"
    fi

    # --- 7. Repack ASAR ---
    step "Repacking app.asar"
    if $DRY_RUN; then
        dry "repack the modified tree back into app.asar"
    else
        asar_cmd pack "$TMP_DIR/app" "$TMP_DIR/app.asar.new"
        cp "$TMP_DIR/app.asar.new" "$PATCHED_ASAR"
        success "Repacked."
    fi

    # --- 8. Disable ASAR integrity fuse ---
    step "Disabling ASAR integrity validation"
    log "Electron validates the ASAR hash at startup; our edits change that hash,"
    log "so this fuse must be off or the patched app crashes on launch."
    if $DRY_RUN; then
        dry "run: @electron/fuses write --app Claude-RTL.app EnableEmbeddedAsarIntegrityValidation=off"
    else
        fuses_cmd write --app "$PATCHED_APP" EnableEmbeddedAsarIntegrityValidation=off 2>&1 | while IFS= read -r line; do
            log "$line"
        done
        success "ASAR integrity fuse disabled."
    fi

    # --- 9. Re-sign ---
    step "Re-signing with an ad-hoc signature"
    log "Our changes invalidate Anthropic's signature; an ad-hoc signature lets macOS run it."
    # Preserve entitlements from the original. Without these, features that
    # check for entitlements at runtime fail — notably Cowork, which calls
    # @ant/claude-swift's VM check and shows "installation appears to be
    # corrupted" when com.apple.security.virtualization is missing.
    #
    # The three team-id-coupled keys are stripped: they reference Anthropic's
    # team ID Q6L2SF6YDW and macOS rejects them under an ad-hoc signature.
    if $DRY_RUN; then
        dry "copy entitlements from the original (keeping virtualization for Cowork)"
        dry "strip team-id keys: application-identifier, team-identifier, keychain-access-groups"
        dry "run: codesign --force --deep --sign - --entitlements <plist> Claude-RTL.app"
    else
        local entitlements_file="$TMP_DIR/entitlements.plist"
        mkdir -p "$TMP_DIR"
        if codesign -d --entitlements :- "$SOURCE_APP" > "$entitlements_file" 2>/dev/null && [ -s "$entitlements_file" ]; then
            /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$entitlements_file" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$entitlements_file" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$entitlements_file" 2>/dev/null || true
            log "Preserving entitlements from original (incl. virtualization for Cowork)..."
            codesign --force --deep --sign - --entitlements "$entitlements_file" "$PATCHED_APP" 2>&1 | while IFS= read -r line; do
                log "$line"
            done
        else
            warn "Could not extract entitlements from original — Cowork will not work."
            codesign --force --deep --sign - "$PATCHED_APP" 2>&1 | while IFS= read -r line; do
                log "$line"
            done
        fi
        success "App re-signed."
    fi

    # --- Cleanup temp ---
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || true
        TMP_DIR=""
    fi

    # --- 10. Launch ---
    step "Launching Claude-RTL"
    run open "$PATCHED_APP"

    # --- Summary ---
    if $DRY_RUN; then
        banner "DRY RUN COMPLETE — nothing was changed" "Re-run without --dry-run to apply."
        echo ""
        echo "    Would patch:   ${BOLD}$SOURCE_APP${NC}"
        echo "    Would create:  ${BOLD}$PATCHED_APP${NC}"
        [ -n "${INJECTED:-}" ] && echo "    Would inject:  ${BOLD}${INJECTED}${NC} renderer file(s), skipping ${BOLD}${SKIPPED:-0}${NC}"
        echo ""
    else
        banner "PATCH INSTALLED SUCCESSFULLY" "Completed in ${SECONDS}s"
        echo ""
        echo "    Patched app:  ${BOLD}$PATCHED_APP${NC}"
        echo "    Original app: ${BOLD}$SOURCE_APP${NC} ${DIM}(untouched)${NC}"
        echo ""
        echo "    Keep both apps — the original Claude.app is not modified."
        echo "    To remove the patch:  ${BOLD}$0 --uninstall${NC}"
        echo ""
        info "First launch may re-prompt for Keychain access and briefly show a blank window — both are expected."
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall_patch() {
    STEP=0; STEP_TOTAL=1

    if $DRY_RUN; then
        banner "Claude Desktop RTL Patcher — Uninstall" "DRY RUN · nothing will be removed"
    else
        banner "Claude Desktop RTL Patcher — Uninstall" "v$VERSION"
    fi

    if [ ! -d "$PATCHED_APP" ]; then
        warn "No patched app found at $PATCHED_APP. Nothing to remove."
        exit 0
    fi

    quit_claude_rtl

    step "Removing patched app"
    run rm -rf "$PATCHED_APP"
    $DRY_RUN || success "Removed $PATCHED_APP"

    if $DRY_RUN; then
        banner "DRY RUN COMPLETE — nothing was removed"
    else
        banner "UNINSTALL COMPLETE" "The original Claude.app was never modified."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    banner "Claude Desktop RTL Patch — Status" "v$VERSION"
    echo ""

    if [ -d "$SOURCE_APP" ]; then
        local version
        version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
        success "Original Claude.app: installed ${DIM}(v$version)${NC}"
    else
        warn "Original Claude.app: not found"
    fi

    if [ -d "$PATCHED_APP" ]; then
        local patched_version
        patched_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")

        # Check if it's actually patched (fuse disabled).
        local fuse_status
        fuse_status=$(npx --yes @electron/fuses read --app "$PATCHED_APP" 2>/dev/null | grep "EnableEmbeddedAsarIntegrityValidation" || echo "unknown")

        if echo "$fuse_status" | grep -q "Disabled"; then
            success "Patched Claude-RTL.app: installed ${DIM}(v$patched_version, fuse disabled)${NC}"
        else
            warn "Patched Claude-RTL.app: found ${DIM}(v$patched_version)${NC} but fuse status unclear"
        fi

        # Friendly nudge when the patched copy lags behind an updated original.
        if [ -d "$SOURCE_APP" ] && [ "${version:-x}" != "${patched_version:-y}" ]; then
            warn "Versions differ — re-run ${BOLD}$0 --install${NC} to rebuild from the updated original."
        fi
    else
        log "Patched Claude-RTL.app: not installed"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    banner "Claude Desktop RTL Patcher for macOS" "v$VERSION"
    cat <<EOF

  ${BOLD}USAGE${NC}
    $0 [ACTION] [OPTIONS]

  ${BOLD}ACTIONS${NC}
    --install            Build & launch ~/Applications/Claude-RTL.app
    --uninstall          Remove the patched app (original is untouched)
    --status             Show installed versions + ASAR fuse state
    (no action)          Open the interactive menu

  ${BOLD}OPTIONS${NC}
    --font NAME          Embed/use NAME as the font for RTL text.
                         Bundled: ${BOLD}Vazirmatn${NC}, ${BOLD}Estedad${NC} (Persian/Arabic, OFL).
                         Drop your own .woff2/.woff/.ttf/.otf in fonts/ (named
                         with the family prefix) to bundle others. Default: no
                         font change. Env equivalent: RTL_FONT_FAMILY=NAME
    -n, --dry-run        Preview every step without changing anything
    -y, --yes            Non-interactive (auto-confirm the menu's install)
        --color[=WHEN]   Colorize output: auto (default), always, never
        --no-color       Disable colors (same as --color=never)
    -V, --version        Print version and exit
    -h, --help           Show this help

  ${BOLD}EXAMPLES${NC}
    $0 --install
    $0 --install --font Vazirmatn
    $0 --install --dry-run            ${DIM}# see exactly what it would do${NC}
    RTL_FONT_FAMILY=Estedad $0 --install

EOF
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    banner "Claude Desktop RTL Patcher (macOS)" "v$VERSION · interactive"
    echo ""
    printf '    %s1%s  Install RTL patch\n'              "$BOLD$GREEN"  "$NC"
    printf '    %s2%s  Uninstall (remove patched app)\n' "$BOLD$YELLOW" "$NC"
    printf '    %s3%s  Show status\n'                    "$BOLD$CYAN"   "$NC"
    printf '    %s4%s  Dry-run install (preview only)\n' "$BOLD$MAGENTA" "$NC"
    printf '    %s5%s  Exit\n'                           "$BOLD$DIM"    "$NC"
    echo ""

    if $ASSUME_YES; then
        info "--yes given — installing without prompting."
        install_patch
        return
    fi

    local choice
    read -rp "  ${BOLD}Choose [1-5]:${NC} " choice
    case "$choice" in
        1) install_patch ;;
        2) uninstall_patch ;;
        3) show_status ;;
        4) DRY_RUN=true; install_patch ;;
        5) exit 0 ;;
        *) err "Invalid choice: '$choice'"; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Main — argument parsing
# ---------------------------------------------------------------------------
# --font NAME may appear before or after the action flag and overrides
# RTL_FONT_FAMILY. Action flags are mutually exclusive.
ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install|--uninstall|--status)
            [ -n "$ACTION" ] && { err "Multiple action flags given: $ACTION and $1"; exit 1; }
            ACTION="$1"; shift ;;
        -n|--dry-run)
            DRY_RUN=true; shift ;;
        -y|--yes)
            ASSUME_YES=true; shift ;;
        --color)
            COLOR_MODE=always; shift ;;
        --color=*)
            COLOR_MODE="${1#--color=}"; shift
            case "$COLOR_MODE" in auto|always|never) ;; *) err "Invalid --color value (use auto|always|never)"; exit 1 ;; esac ;;
        --no-color)
            COLOR_MODE=never; shift ;;
        --font)
            [ $# -lt 2 ] && { err "--font requires a font family name (e.g. --font Vazirmatn)"; exit 1; }
            RTL_FONT_FAMILY="$2"; shift 2 ;;
        --font=*)
            RTL_FONT_FAMILY="${1#--font=}"; shift ;;
        -V|--version)
            echo "Claude Desktop RTL Patcher v$VERSION"; exit 0 ;;
        -h|--help)
            COLOR_MODE="$COLOR_MODE"; setup_colors; usage; exit 0 ;;
        "")
            shift ;;
        *)
            setup_colors; err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

setup_colors

case "$ACTION" in
    --install)   install_patch ;;
    --uninstall) uninstall_patch ;;
    --status)    show_status ;;
    "")
        # If --font was given without an action, the user clearly wanted a
        # flag-driven invocation — don't silently drop into the menu.
        if [ -n "$RTL_FONT_FAMILY" ]; then
            err "--font requires an action flag (e.g. --install --font $RTL_FONT_FAMILY)."
            exit 1
        fi
        interactive_menu ;;
esac
