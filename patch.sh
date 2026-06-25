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
#   Each step runs under a live gradient spinner that tails the job's stdout
#   inline, then collapses to a ✓ summary. Run --help for usage, --dry-run to
#   preview (spinner off so every action is printed), --no-color for plain logs.
# ============================================================================

set -euo pipefail

VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_FILE="$SCRIPT_DIR/rtl-payload.js"
ICON_FILE="$SCRIPT_DIR/icon.icns"
FONTS_DIR="$SCRIPT_DIR/fonts"

# Font used for RTL (Hebrew/Arabic/Persian) text. Defaults to the bundled
# Estedad family; override or disable it either way:
#   * Command line:  ./patch.sh --install --font Vazirmatn
#   * Environment:   RTL_FONT_FAMILY=Vazirmatn ./patch.sh --install
#   * Disable:       ./patch.sh --install --font "" (keep Claude's own font)
# Vazirmatn and Estedad (Persian/Arabic, OFL) are bundled in fonts/. To use a
# different font, drop your own .woff2/.woff/.ttf/.otf files in fonts/ and pass
# --font "<family-name>" (the embedded files mean it works even if the font
# isn't installed on the system). With no matching files in fonts/ the patch
# falls back to an already-installed font of that name.
# The --font flag overrides RTL_FONT_FAMILY when both are set.
RTL_FONT_FAMILY="${RTL_FONT_FAMILY-Estedad}"

SOURCE_APP="/Applications/Claude.app"
SOURCE_ASAR="$SOURCE_APP/Contents/Resources/app.asar"
PATCHED_APP="$HOME/Applications/Claude-RTL.app"
PATCHED_ASAR="$PATCHED_APP/Contents/Resources/app.asar"

TMP_DIR=""
HEADER_FILE=""      # combined RTL+font header; set by job_header, read by job_inject
INJECTED=0          # set by inject_payload
SKIPPED=0           # set by inject_payload

# Runtime modes (set by the argument parser, see Main).
DRY_RUN=false       # --dry-run / -n : preview only, never mutate anything
COLOR_MODE=auto     # auto | always | never
ASSUME_YES=false    # --yes / -y : skip the interactive menu confirmation
FONT_EXPLICIT=false # true once --font is passed on the CLI (the default font is non-empty, so emptiness can't signal intent)
DEPS_OK=true        # set by check_dependencies

# Progress / spinner state.
STEP=0
STEP_TOTAL=0
SPINNER_ENABLED=false
TRUECOLOR=false
SPIN_PID=""
SPIN_LOG=""
SPIN_TITLE=""
GRAD_TITLE=""
JOB_NOTE=""
# Braille spinner frames kept in an ARRAY: bash 3.2 substring is byte-indexed,
# so slicing these 3-byte glyphs out of a string would corrupt them.
SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
# Resolved *after* argument parsing so --color/--no-color and the NO_COLOR
# convention can take effect. Until then they are empty (no-ops).
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
        # 24-bit gradients only when the terminal advertises truecolor.
        case "${COLORTERM:-}" in truecolor|24bit) TRUECOLOR=true ;; esac
    fi
}

# ---------------------------------------------------------------------------
# Gradient text (24-bit truecolor, with graceful fallback)
# ---------------------------------------------------------------------------
# gradient TEXT R1 G1 B1 R2 G2 B2 — paints TEXT with a per-character color ramp
# from (R1,G1,B1) to (R2,G2,B2). Falls back to bold-cyan without truecolor, and
# to plain text when colors are off. Always ends reset so nothing bleeds.
gradient() {
    local text="$1" r1=$2 g1=$3 b1=$4 r2=$5 g2=$6 b2=$7
    if [ -z "$NC" ]; then printf '%s' "$text"; return; fi
    if ! $TRUECOLOR; then printf '%s%s%s' "$BOLD$CYAN" "$text" "$NC"; return; fi
    local n=${#text} i ch r g b out=''
    for ((i = 0; i < n; i++)); do
        ch=${text:i:1}
        if [ "$n" -le 1 ]; then r=$r1; g=$g1; b=$b1; else
            r=$(( r1 + (r2 - r1) * i / (n - 1) ))
            g=$(( g1 + (g2 - g1) * i / (n - 1) ))
            b=$(( b1 + (b2 - b1) * i / (n - 1) ))
        fi
        out+=$'\033[1;38;2;'"${r};${g};${b}m${ch}"
    done
    printf '%s%s' "$out" "$NC"
}

# Brand ramp: electric cyan → fuchsia.
grad() { gradient "$1" 34 211 238 232 121 249; }

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()     { printf '   %s•%s %s\n'  "$DIM"     "$NC" "$1"; }
success() { printf '   %s✓%s %s\n'  "$GREEN"   "$NC" "$1"; }
warn()    { printf '   %s▲%s %s\n'  "$YELLOW"  "$NC" "$1"; }
err()     { printf '   %s✗%s %s\n'  "$RED"     "$NC" "$1" >&2; }
info()    { printf '   %sℹ%s %s\n'  "$BLUE"    "$NC" "$1"; }
dry()     { printf '   %s◌%s %s%swould%s %s\n' "$MAGENTA" "$NC" "$DIM" "$MAGENTA" "$NC" "$1"; }

# A gradient framed banner. The border is a single color; the title text is
# gradient-painted with manual padding so the embedded color codes never throw
# off the box width.
banner() {
    local title="$1" subtitle="${2:-}"
    printf '\n%s  ╭──────────────────────────────────────────────────────╮%s\n' "$CYAN" "$NC"
    _box_line "$title"
    [ -n "$subtitle" ] && _box_line "$subtitle"
    printf '%s  ╰──────────────────────────────────────────────────────╯%s\n' "$CYAN" "$NC"
}
_box_line() {
    local s="$1" pad
    pad=$(( 52 - ${#s} )); [ "$pad" -lt 0 ] && pad=0
    printf '%s  │  %s' "$CYAN" "$NC"
    grad "$s"
    printf '%*s%s│%s\n' "$pad" '' "$CYAN" "$NC"
}

# Run a simple command, or just describe it in dry-run mode.
run() {
    if $DRY_RUN; then dry "$*"; return 0; fi
    "$@"
}

die() { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Spinner + grouped jobs
# ---------------------------------------------------------------------------
# The animator runs in the BACKGROUND and tails a shared logfile; the job runs
# in the FOREGROUND with stdout/stderr redirected into that same logfile. This
# split is deliberate: the job mutates parent-shell state (TMP_DIR, INJECTED,
# HEADER_FILE), which a backgrounded subshell would silently lose.
_spin_animate() {
    set +e   # subshell-local: a stray non-zero (e.g. tput) must not kill the spin
    local i=0 fr cols last avail
    while :; do
        fr=${SPIN_FRAMES[$i]}; i=$(( (i + 1) % ${#SPIN_FRAMES[@]} ))
        cols=$(tput cols 2>/dev/null || echo 80)
        # Latest line of job output, stripped of CR and ANSI so width math holds.
        last=$(tail -n1 "$SPIN_LOG" 2>/dev/null | tr -d '\r' | sed $'s/\033\\[[0-9;]*m//g')
        avail=$(( cols - ${#SPIN_TITLE} - 8 )); [ "$avail" -lt 4 ] && avail=4
        last=${last:0:$avail}
        printf '\r\033[K  %s%s%s %s   %s%s%s' "$CYAN" "$fr" "$NC" "$GRAD_TITLE" "$DIM" "$last" "$NC"
        sleep 0.08
    done
}

spinner_start() {
    SPIN_TITLE="$1"
    GRAD_TITLE=$(grad "$SPIN_TITLE")
    SPIN_LOG=$(mktemp)
    printf '\033[?25l'           # hide cursor while the line animates
    _spin_animate &
    SPIN_PID=$!
}

spinner_stop() {
    local rc="$1" secs="$2"
    if [ -n "${SPIN_PID:-}" ]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""
    fi
    printf '\r\033[K'            # wipe the spinner line
    if [ "$rc" -eq 0 ]; then
        printf '  %s✓%s %s' "$GREEN" "$NC" "$GRAD_TITLE"
        [ -n "$JOB_NOTE" ] && printf '  %s%s%s' "$DIM" "$JOB_NOTE" "$NC"
        printf ' %s(%ss)%s\n' "$DIM" "$secs" "$NC"
    else
        printf '  %s✗%s %s  %s(failed)%s\n' "$RED" "$NC" "$GRAD_TITLE" "$DIM" "$NC"
        [ -s "$SPIN_LOG" ] && sed 's/^/      /' "$SPIN_LOG"   # surface what broke
    fi
    printf '\033[?25h'          # restore cursor
    rm -f "$SPIN_LOG" 2>/dev/null || true
    SPIN_LOG=""
}

# group "Title" job_function [args...] — the one entry point each step uses.
# Spinner mode: animate + collapse. Plain/dry mode: print heading, run inline,
# print a settled ✓ line. Either way a failed job is fatal.
group() {
    local title="$1"; shift
    STEP=$(( STEP + 1 ))
    local label="[$STEP/$STEP_TOTAL] $title"
    local start rc secs
    JOB_NOTE=""
    start=$(date +%s)

    if $SPINNER_ENABLED; then
        spinner_start "$label"
        set +e; "$@" >>"$SPIN_LOG" 2>&1; rc=$?; set -e
        secs=$(( $(date +%s) - start ))
        spinner_stop "$rc" "$secs"
        [ "$rc" -ne 0 ] && die "Step failed: $title"
    else
        printf '\n  %s▸%s ' "$BOLD$CYAN" "$NC"; grad "$label"; printf '\n'
        "$@"
        secs=$(( $(date +%s) - start ))
        printf '  %s✓%s ' "$GREEN" "$NC"; grad "$label"
        [ -n "$JOB_NOTE" ] && printf '  %s%s%s' "$DIM" "$JOB_NOTE" "$NC"
        printf ' %s(%ss)%s\n' "$DIM" "$secs" "$NC"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    # If we die mid-spinner, kill the animator, surface its captured log, and
    # always restore the cursor so the terminal is never left hidden.
    if [ -n "${SPIN_PID:-}" ]; then kill "$SPIN_PID" 2>/dev/null || true; fi
    printf '\033[?25h' 2>/dev/null || true
    if [ -n "${SPIN_LOG:-}" ] && [ -s "${SPIN_LOG:-/nonexistent}" ]; then
        printf '\r\033[K'
        sed 's/^/      /' "$SPIN_LOG" 2>/dev/null || true
        rm -f "$SPIN_LOG" 2>/dev/null || true
    fi
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
        log "Font: none (default) — RTL text keeps Claude's font. Use --font NAME to opt in."
        JOB_NOTE="no font (default)"
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
            log "embed $(basename "$f") → weight ${weight}, ${style}"
        done
        shopt -u nullglob nocaseglob
    fi

    # Apply the family to RTL text. Fallbacks cover Hebrew/Latin glyphs the
    # chosen font may lack; code stays monospace. (Selectors use single quotes.)
    # font-feature-settings enables the family's stylistic sets (ss01–ss20) —
    # Estedad uses these for nicer Persian glyph shaping; harmless for fonts
    # that don't define them.
    local feature_settings="font-feature-settings:'ss01' on,'ss02' on,'ss03' on,'ss10' on,'ss11' on,'ss12' on,'ss20' on"
    face_css+="[dir='rtl'],[dir='rtl'] *,[data-testid='chat-input'],.tiptap.ProseMirror{font-family:'${family}',Tahoma,-apple-system,system-ui,sans-serif!important;${feature_settings}!important}"
    face_css+="[dir='rtl'] pre,[dir='rtl'] code,[dir='rtl'] pre *,[dir='rtl'] code *,.tiptap.ProseMirror pre,.tiptap.ProseMirror code,.tiptap.ProseMirror pre *,.tiptap.ProseMirror code *{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace!important;font-feature-settings:normal!important}"

    {
        printf '\n// --- CLAUDE RTL FONT START ---\n'
        printf ';(function(){if(typeof document==="undefined")return;function add(){if(document.getElementById("claude-rtl-font"))return;if(!document.head&&!document.documentElement)return;var s=document.createElement("style");s.id="claude-rtl-font";s.textContent="%s";(document.head||document.documentElement).appendChild(s);}if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",add);}else{add();}})();\n' "$face_css"
        printf '// --- CLAUDE RTL FONT END ---\n'
    } >> "$header"

    if [ "$embedded" -gt 0 ]; then
        success "Font: $family — embedded $embedded file(s) from fonts/ as base64 data: URIs."
        JOB_NOTE="$family · $embedded file(s) embedded"
    else
        warn "Font: $family — no files in fonts/, relying on an installed font of that name."
        JOB_NOTE="$family · system fallback"
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
            log "skip $name (Electron main process)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Skip already-patched files (idempotent).
        if grep -q "CLAUDE RTL PATCH START" "$js_file" 2>/dev/null; then
            log "skip $name (already patched)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        if $DRY_RUN; then
            dry "inject RTL header into $name"
        else
            # Prepend the combined header (RTL payload + font) to each JS file.
            cat "$header" "$js_file" > "$app_dir/.rtl-merged.js"
            mv "$app_dir/.rtl-merged.js" "$js_file"
            log "inject → $name"
        fi
        INJECTED=$((INJECTED + 1))
    done

    if [ "$INJECTED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
        die "No .js files found in .vite/build/. Claude Desktop structure may have changed."
    fi
    JOB_NOTE="${INJECTED} injected · ${SKIPPED} skipped"
}

# ---------------------------------------------------------------------------
# Install — job bodies (each is one group)
# ---------------------------------------------------------------------------
job_copy() {
    run mkdir -p "$HOME/Applications"
    if [ -d "$PATCHED_APP" ]; then
        log "Removing previous patched copy..."
        run rm -rf "$PATCHED_APP"
    fi
    log "Copying Claude.app → Claude-RTL.app (this may take a moment)..."
    run cp -R "$SOURCE_APP" "$PATCHED_APP"
    $DRY_RUN || success "Created $PATCHED_APP"
}

job_icon() {
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
}

job_rename() {
    # Use CFBundleDisplayName (cosmetic only) — changing CFBundleName breaks Electron's fuse lookup.
    if $DRY_RUN; then
        dry "set CFBundleDisplayName = Claude-RTL in Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude-RTL" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Claude-RTL" "$PATCHED_APP/Contents/Info.plist"
        success "App will show as \"Claude-RTL\" in Dock and Finder."
    fi
}

job_extract() {
    # In dry-run we read the *source* ASAR (read-only) so the preview reflects
    # the real bundle; in a normal run we work on the patched copy's ASAR.
    if $DRY_RUN && ! $DEPS_OK; then
        warn "asar unavailable — skipping the file-level preview."
        return 0
    fi
    TMP_DIR=$(mktemp -d)
    local extract_from
    if $DRY_RUN; then extract_from="$SOURCE_ASAR"; else extract_from="$PATCHED_ASAR"; fi
    asar_cmd extract "$extract_from" "$TMP_DIR/app"
    success "Extracted."
    JOB_NOTE="from $(basename "$extract_from")"
}

job_header() {
    # The font is embedded as a base64 data: URI rather than loaded from a CDN
    # or a local file: Claude's CSP is "font-src 'self' data:" in the main window
    # and "font-src data:" in the artifact preview sandbox, with connect-src 'none'
    # — so external hosts are blocked and only data: URIs work in every context.
    if [ -n "$TMP_DIR" ]; then
        HEADER_FILE="$TMP_DIR/rtl-header.js"
        cp "$PAYLOAD_FILE" "$HEADER_FILE"
        build_font_injector "$HEADER_FILE"
    else
        # No temp dir (dry-run without deps) — still report what the font step would do.
        build_font_injector /dev/null
    fi
}

job_inject() {
    if [ -n "$TMP_DIR" ] && [ -n "$HEADER_FILE" ]; then
        inject_payload "$TMP_DIR/app" "$HEADER_FILE"
    else
        dry "inject the RTL header into every renderer .js under .vite/build/"
    fi
}

job_repack() {
    if $DRY_RUN; then
        dry "repack the modified tree back into app.asar"
    else
        asar_cmd pack "$TMP_DIR/app" "$TMP_DIR/app.asar.new"
        cp "$TMP_DIR/app.asar.new" "$PATCHED_ASAR"
        success "Repacked."
    fi
}

job_fuse() {
    log "Electron validates the ASAR hash at startup; our edits change that hash,"
    log "so this fuse must be off or the patched app crashes on launch."
    if $DRY_RUN; then
        dry "run: @electron/fuses write --app Claude-RTL.app EnableEmbeddedAsarIntegrityValidation=off"
    else
        fuses_cmd write --app "$PATCHED_APP" EnableEmbeddedAsarIntegrityValidation=off 2>&1
        success "ASAR integrity fuse disabled."
    fi
}

job_resign() {
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
        return 0
    fi
    local entitlements_file="$TMP_DIR/entitlements.plist"
    mkdir -p "$TMP_DIR"
    if codesign -d --entitlements :- "$SOURCE_APP" > "$entitlements_file" 2>/dev/null && [ -s "$entitlements_file" ]; then
        /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$entitlements_file" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$entitlements_file" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$entitlements_file" 2>/dev/null || true
        log "Preserving entitlements from original (incl. virtualization for Cowork)..."
        codesign --force --deep --sign - --entitlements "$entitlements_file" "$PATCHED_APP" 2>&1
    else
        warn "Could not extract entitlements from original — Cowork will not work."
        codesign --force --deep --sign - "$PATCHED_APP" 2>&1
    fi
    success "App re-signed."
}

job_launch() {
    run open "$PATCHED_APP"
}

job_remove() {
    run rm -rf "$PATCHED_APP"
    $DRY_RUN || success "Removed $PATCHED_APP"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_patch() {
    SECONDS=0
    STEP=0; STEP_TOTAL=10
    HEADER_FILE=""

    if $DRY_RUN; then
        banner "Claude Desktop RTL Patcher — Install" "DRY RUN · nothing will be modified"
    else
        banner "Claude Desktop RTL Patcher — Install" "v$VERSION"
    fi

    # --- Preflight (ungrouped: must run before the spinner choreography) ---
    [ ! -d "$SOURCE_APP" ] && die "Claude.app not found at $SOURCE_APP. Is Claude Desktop installed?"
    [ ! -f "$PAYLOAD_FILE" ] && die "rtl-payload.js not found at $PAYLOAD_FILE. Re-clone the repository."
    check_dependencies
    quit_claude_rtl

    # --- The ten grouped jobs, each under its own gradient spinner ---
    group "Creating patched copy"            job_copy
    group "Replacing app icon"               job_icon
    group "Renaming app to Claude-RTL"       job_rename
    group "Extracting app.asar"              job_extract
    group "Building RTL + font header"       job_header
    group "Injecting RTL code"               job_inject
    group "Repacking app.asar"               job_repack
    group "Disabling ASAR integrity fuse"    job_fuse
    group "Re-signing (ad-hoc signature)"    job_resign

    # Drop the temp tree before launching (kept until now for re-sign entitlements).
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || true
        TMP_DIR=""
    fi

    group "Launching Claude-RTL"             job_launch

    # --- Summary ---
    if $DRY_RUN; then
        banner "DRY RUN COMPLETE — nothing was changed" "Re-run without --dry-run to apply."
        echo ""
        printf '    Would patch:   '; grad "$SOURCE_APP"; printf '\n'
        printf '    Would create:  '; grad "$PATCHED_APP"; printf '\n'
        [ "${INJECTED:-0}" -gt 0 ] && { printf '    Would inject:  '; grad "${INJECTED} renderer file(s), skipping ${SKIPPED:-0}"; printf '\n'; }
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
    group "Removing patched app" job_remove

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
                         with the family prefix) to bundle others. Default:
                         ${BOLD}Estedad${NC} (use --font "" to keep Claude's own font).
                         Env equivalent: RTL_FONT_FAMILY=NAME
    -n, --dry-run        Preview every step without changing anything
    -y, --yes            Non-interactive (auto-confirm the menu's install)
        --color[=WHEN]   Colorize output: auto (default), always, never
        --no-color       Disable colors & spinner (same as --color=never)
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
        4) DRY_RUN=true; SPINNER_ENABLED=false; install_patch ;;
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
            RTL_FONT_FAMILY="$2"; FONT_EXPLICIT=true; shift 2 ;;
        --font=*)
            RTL_FONT_FAMILY="${1#--font=}"; FONT_EXPLICIT=true; shift ;;
        -V|--version)
            echo "Claude Desktop RTL Patcher v$VERSION"; exit 0 ;;
        -h|--help)
            setup_colors; usage; exit 0 ;;
        "")
            shift ;;
        *)
            setup_colors; err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

setup_colors

# The spinner needs a live TTY and colors, and is pointless in dry-run (where we
# WANT every "would …" line printed, not collapsed).
if [ -n "$NC" ] && [ -t 1 ] && ! $DRY_RUN; then
    SPINNER_ENABLED=true
fi

case "$ACTION" in
    --install)   install_patch ;;
    --uninstall) uninstall_patch ;;
    --status)    show_status ;;
    "")
        # If --font was given without an action, the user clearly wanted a
        # flag-driven invocation — don't silently drop into the menu. (The
        # default font is non-empty, so we key off explicit use, not emptiness.)
        if $FONT_EXPLICIT; then
            err "--font requires an action flag (e.g. --install --font $RTL_FONT_FAMILY)."
            exit 1
        fi
        interactive_menu ;;
esac
