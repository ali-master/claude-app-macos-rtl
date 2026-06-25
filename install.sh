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

# --- minimal color (honors NO_COLOR and non-TTY) ---------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_CYAN=$'\033[0;36m'; C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'
    C_DIM=$'\033[2m';     C_BOLD=$'\033[1m';     C_NC=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_RED=''; C_DIM=''; C_BOLD=''; C_NC=''
fi
say()  { printf '%s▸%s %s\n' "$C_CYAN"  "$C_NC" "$1"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_NC" "$1"; }
die()  { printf '%s✗%s %s\n' "$C_RED"   "$C_NC" "$1" >&2; exit 1; }

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
trap 'rm -rf "$TMP"' EXIT

printf '\n%s  Claude Desktop RTL — installer%s\n\n' "$C_BOLD" "$C_NC"
say "Fetching ${C_DIM}${REPO}@${REF}${C_NC} ..."
fetch "$TARBALL" "$TMP/src.tar.gz" || die "Download failed from: $TARBALL"
ok "Downloaded."

say "Extracting ..."
tar -xzf "$TMP/src.tar.gz" -C "$TMP" || die "Extract failed — the tarball looks corrupt."
# The archive's single top-level directory (e.g. repo-master); read it from the listing.
TOP="$(tar -tzf "$TMP/src.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
SRC="$TMP/$TOP"
[ -n "$TOP" ] && [ -d "$SRC" ] || die "Could not locate the extracted source directory."
[ -f "$SRC/patch.sh" ] || die "patch.sh not found in the downloaded repo — wrong REPO/REF?"
ok "Extracted to a temp dir."

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
say "Running: ${C_BOLD}patch.sh $*${C_NC}"
printf '%s  ────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_NC"

# Run from inside the repo so patch.sh resolves rtl-payload.js / icon.icns / fonts/.
# Not exec'd, so the EXIT trap still cleans up the temp checkout afterwards.
( cd "$SRC" && ./patch.sh "$@" )
