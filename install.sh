#!/usr/bin/env bash
# ============================================================================
#   Claude Desktop RTL — one-command remote installer
#
#   Downloads this repository (tarball, no git needed) into a temp dir and runs
#   patch.sh from it. The patcher needs the whole repo — rtl-payload.js,
#   icon.icns and the bundled fonts/ — so a single file won't do; we fetch and
#   extract the lot, run the patch, then delete the temp copy.
#
#   Usage (install):
#     curl -fsSL https://raw.githubusercontent.com/ali-master/claude-app-macos-rtl/master/install.sh | bash
#
#   Forward any patch.sh flags after `bash -s --`, e.g. preview without changes:
#     curl -fsSL .../install.sh | bash -s -- --dry-run
#     curl -fsSL .../install.sh | bash -s -- --install --font Vazirmatn
#
#   Overrides (env):
#     CLAUDE_RTL_REPO=owner/name     pull from a fork              (default: ali-master/claude-app-macos-rtl)
#     CLAUDE_RTL_REF=branch-or-tag   pull a specific ref          (default: master)
#     CLAUDE_RTL_TARBALL=path|url    use a local/remote tarball   (mainly for testing)
# ============================================================================

set -euo pipefail

REPO="${CLAUDE_RTL_REPO:-ali-master/claude-app-macos-rtl}"
REF="${CLAUDE_RTL_REF:-master}"
TARBALL="${CLAUDE_RTL_TARBALL:-https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}}"

# --- color + gradient + spinner (honors NO_COLOR and non-TTY) --------------
TRUECOLOR=false
SPINNER_ENABLED=false
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_CYAN=$'\033[0;36m'; C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'
    C_DIM=$'\033[2m';     C_BOLD=$'\033[1m';     C_NC=$'\033[0m'
    SPINNER_ENABLED=true
    case "${COLORTERM:-}" in truecolor|24bit) TRUECOLOR=true ;; esac
else
    C_CYAN=''; C_GREEN=''; C_RED=''; C_DIM=''; C_BOLD=''; C_NC=''
fi

# Braille spinner frames (3-byte glyphs — kept in an array, never string-sliced).
SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# gradient TEXT — paints TEXT with a per-character cyan→fuchsia ramp (24-bit).
# Falls back to bold-cyan without truecolor, and to plain text when colors are off.
gradient() {
    local text="$1" r1=34 g1=211 b1=238 r2=232 g2=121 b2=249
    if [ -z "$C_NC" ]; then printf '%s' "$text"; return; fi
    if ! $TRUECOLOR; then printf '%s%s%s' "$C_BOLD$C_CYAN" "$text" "$C_NC"; return; fi
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
    printf '%s%s' "$out" "$C_NC"
}

say()  { printf '%s▸%s %s\n' "$C_CYAN"  "$C_NC" "$1"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_NC" "$1"; }
die()  { printf '%s✗%s %s\n' "$C_RED"   "$C_NC" "$1" >&2; exit 1; }

# spin "Title" cmd [args...] — run cmd under a live gradient spinner, collapsing
# to a ✓/✗ line. Without a TTY it just prints the title and runs inline. The cmd
# runs in the background and the animator polls it, so no parent state is needed.
spin() {
    local title="$1"; shift
    local grad_title; grad_title=$(gradient "$title")
    if ! $SPINNER_ENABLED; then
        say "$title ..."
        "$@"
        return $?
    fi
    local logf; logf=$(mktemp)
    "$@" >"$logf" 2>&1 &
    local pid=$! i=0 fr rc
    printf '\033[?25l'                                   # hide cursor
    while kill -0 "$pid" 2>/dev/null; do
        fr=${SPIN_FRAMES[$i]}; i=$(( (i + 1) % ${#SPIN_FRAMES[@]} ))
        printf '\r\033[K  %s%s%s %s' "$C_CYAN" "$fr" "$C_NC" "$grad_title"
        sleep 0.08
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    printf '\r\033[K'                                    # wipe spinner line
    if [ "$rc" -eq 0 ]; then
        printf '  %s✓%s %s\n' "$C_GREEN" "$C_NC" "$grad_title"
    else
        printf '  %s✗%s %s\n' "$C_RED" "$C_NC" "$grad_title"
        [ -s "$logf" ] && sed 's/^/      /' "$logf" >&2  # surface what broke
    fi
    printf '\033[?25h'                                   # restore cursor
    rm -f "$logf"
    return $rc
}

# Always restore the cursor on exit, even if interrupted mid-spin.
restore_cursor() { printf '\033[?25h' 2>/dev/null || true; }

# --- preflight -------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This patcher is macOS-only (detected: $(uname -s))."

# Pick a downloader. Local paths/file: URLs are copied directly (used for testing).
fetch() {
    local url="$1" out="$2"
    case "$url" in
        http://*|https://*)
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$url" -o "$out"
            elif command -v wget >/dev/null 2>&1; then
                wget -qO "$out" "$url"
            else
                die "Need curl or wget to download. Install one and retry."
            fi
            ;;
        file://*) cp "${url#file://}" "$out" ;;
        *)        cp "$url" "$out" ;;
    esac
}

# --- download + extract into a self-cleaning temp dir ----------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-rtl.XXXXXX")"
trap 'restore_cursor; rm -rf "$TMP"' EXIT

printf '\n  '; gradient "Claude Desktop RTL — installer"; printf '\n\n'

spin "Fetching ${REPO}@${REF}" fetch "$TARBALL" "$TMP/src.tar.gz" || die "Download failed from: $TARBALL"
spin "Extracting archive"      tar -xzf "$TMP/src.tar.gz" -C "$TMP" || die "Extract failed — the tarball looks corrupt."

# The archive's single top-level directory (e.g. repo-master); read it from the listing.
TOP="$(tar -tzf "$TMP/src.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
SRC="$TMP/$TOP"
[ -n "$TOP" ] && [ -d "$SRC" ] || die "Could not locate the extracted source directory."
[ -f "$SRC/patch.sh" ] || die "patch.sh not found in the downloaded repo — wrong REPO/REF?"

# --- run the patcher -------------------------------------------------------
# Default to --install (the installer's job). If the caller passes modifiers
# like --dry-run / --font but no action flag, prepend --install so it doesn't
# fall into patch.sh's interactive menu (which can't read from a curl | bash pipe).
have_action=false
for a in "$@"; do
    case "$a" in --install|--uninstall|--status) have_action=true ;; esac
done
$have_action || set -- --install "$@"
chmod +x "$SRC/patch.sh" 2>/dev/null || true
printf '  %s▸%s ' "$C_CYAN" "$C_NC"; gradient "Running patch.sh $*"; printf '\n'
printf '%s  ────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_NC"

# Run from inside the repo so patch.sh resolves rtl-payload.js / icon.icns / fonts/.
# Not exec'd, so the EXIT trap still cleans up the temp checkout afterwards.
( cd "$SRC" && ./patch.sh "$@" )
