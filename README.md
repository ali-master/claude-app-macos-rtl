# Claude Desktop RTL Patch for macOS

Adds automatic right-to-left (RTL) text support to [Claude Desktop](https://claude.ai/download) on macOS. Hebrew and Arabic text is detected in real-time and aligned properly — both in the chat input and in Claude's responses — while code blocks stay left-to-right.

## What it does

- **Chat input**: automatically switches to RTL alignment when you type Hebrew/Arabic
- **Claude's responses**: detects RTL text in real-time as responses stream in
- **Code blocks**: always stay LTR — code formatting is never affected
- **Math expressions**: LaTeX/KaTeX, MathJax, and MathML always stay LTR — equations are never mirrored
- **Mixed content**: smart 3-layer detection handles sentences mixing Hebrew/Arabic and English
- **Non-destructive**: creates a patched *copy* of Claude.app — the original is never modified
- **Distinct icon**: the patched app has an "RTL" badge on its icon so you can tell them apart at a glance

## Before & After

| Without patch | With patch |
|:---:|:---:|
| Hebrew/Arabic text left-aligned, hard to read | Hebrew/Arabic text properly right-aligned |
| `שלום עולם` / `مرحبا بالعالم` stuck to the left | `שלום עולם` / `مرحبا بالعالم` aligned to the right |

## Requirements

- **macOS** (tested on macOS 15 Sequoia / macOS 26 Tahoe)
- **Claude Desktop** installed at `/Applications/Claude.app`
- **Node.js** (v16+) — needed for `npx` which runs `@electron/asar` and `@electron/fuses`
  - Install via [nodejs.org](https://nodejs.org/) or `brew install node`

## Quick Start

```bash
# Clone the repo
git clone https://github.com/ali-master/claude-desktop-rtl-mac.git
cd claude-desktop-rtl-mac

# Install the patch
./patch.sh --install
```

> **Downloaded the ZIP instead of cloning?** You may need to make the script executable first: `chmod +x patch.sh`

That's it. A patched copy is created at `~/Applications/Claude-RTL.app` (your home folder, not `/Applications/`) and launches automatically.

## Usage

```bash
# Install (or update after Claude updates)
./patch.sh --install

# Remove the patched copy
./patch.sh --uninstall

# Check status
./patch.sh --status

# Interactive menu
./patch.sh

# Show help
./patch.sh --help
```

### Optional: custom font for RTL text

By default the patch leaves Claude's font alone — only direction is changed. If you want a dedicated font for Hebrew/Arabic/Persian text (and especially if Claude's default font has poor Persian/Arabic glyphs), opt in with `--font NAME`:

```bash
# Use a bundled font (Persian/Arabic, OFL licensed — see fonts/OFL.txt)
./patch.sh --install --font Vazirmatn
./patch.sh --install --font Estedad

# Use any font already installed on your system
./patch.sh --install --font "B Nazanin"
```

Two fonts ship in `fonts/`, both Persian/Arabic with full Latin coverage: **Vazirmatn** and **Estedad** (9 weights, Thin → Black). Bundled fonts get embedded as base64 `data:` URIs (Claude's CSP blocks external font loads), so they work even if not installed on the system. To bundle a different font, drop your own `.woff2/.woff/.ttf/.otf` files into `fonts/` — name them so they start with the family name (e.g. `MyFont-Bold.woff2`) — and pass `--font "<family-name>"`. Code blocks always stay monospace regardless of the chosen font.

> **Hebrew users:** Vazirmatn and Estedad don't ship Hebrew glyphs — Hebrew falls through to the system Hebrew font, so these fonts only affect Latin glyphs in your Hebrew sentences. For Hebrew-first use, leave the default off or bundle a Hebrew-friendly font (e.g. Heebo, Rubik, Assistant) in `fonts/`.

## How it works

The patcher performs these steps:

1. **Copies** `/Applications/Claude.app` → `~/Applications/Claude-RTL.app`
2. **Extracts** the Electron `app.asar` archive
3. **Prepends** the RTL detection JavaScript into `.vite/build/*.js` renderer files
4. **Repacks** the `app.asar` archive
5. **Disables** the `EnableEmbeddedAsarIntegrityValidation` Electron fuse — this is required because the modified archive has a different hash, and Electron would crash on startup without this step
6. **Re-signs** the app with an ad-hoc code signature

The original `/Applications/Claude.app` is **never touched**.

### Why a copy instead of patching in-place?

Unlike the [Windows version](https://github.com/shraga100/claude-desktop-rtl-patch) which patches the original installation directly, the macOS version creates a separate copy. This is safer because:

- **No sudo required** — `~/Applications/` is user-writable, so the script never needs elevated privileges
- **Original stays intact** — `/Applications/Claude.app` is never touched; you can always fall back to it
- **Auto-updates keep working** — Anthropic's updates go to the original app and won't conflict with the patch
- **No risk of breaking Claude** — if anything goes wrong, just delete the patched copy and the original is still there
- **macOS protections respected** — `/Applications/Claude.app` is owned by root and protected by App Management permissions; modifying it would require sudo and bypassing macOS security features

## After Claude updates

When Claude Desktop auto-updates, it updates the original at `/Applications/Claude.app`. Your patched copy at `~/Applications/Claude-RTL.app` is a separate, independent app — it won't receive auto-updates. After Claude updates, re-run the patcher to create a fresh patched copy from the new version:

```bash
./patch.sh --install
```

This creates a fresh patched copy from the updated original.

**Tip:** Keep the original `Claude.app` around for updates. Let it update itself normally, then re-run the patcher. The patched copy may show update prompts, but updates won't apply correctly to it — always update via the original app.

## Uninstalling

```bash
./patch.sh --uninstall
```

This removes `~/Applications/Claude-RTL.app`. The original Claude.app is unaffected.
