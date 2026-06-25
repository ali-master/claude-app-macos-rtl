# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A macOS-specific patcher that adds RTL (Hebrew/Arabic/Persian) support to Claude Desktop. It does **not** modify the original `/Applications/Claude.app` — it produces a separate patched copy at `~/Applications/Claude-RTL.app`. The RTL detection JS (`rtl-core.js`) originates from the upstream Windows project [shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch); the value-add of this repo is the macOS patching pipeline (`patch.sh`).

## Commands

```bash
./patch.sh --install                 # Build patched copy at ~/Applications/Claude-RTL.app and launch it
./patch.sh --install --font Vazirmatn # Same, but embed the bundled Vazirmatn font for RTL text
./patch.sh --install --font Estedad   # Same, but embed the bundled Estedad font
./patch.sh --uninstall               # Delete the patched copy (original is never touched)
./patch.sh --status                  # Show installed versions + ASAR fuse state
./patch.sh                           # Interactive menu (no args)
```

`--install` is idempotent — re-running it removes any prior patched copy first, and the JS injection itself is guarded by a `CLAUDE RTL PATCH START` marker. There is **no test suite, lint, or build step**; the only artifact is the patched `.app` bundle.

Runtime deps (checked by `check_dependencies` in [patch.sh:80](patch.sh#L80)): `npx` (Node ≥16, used to fetch `@electron/asar` and `@electron/fuses` on demand) and `codesign` (Xcode CLI tools). No `package.json` — npm tooling is invoked via `npx --yes`.

## Patching pipeline (patch.sh)

The whole pipeline lives in [patch.sh](patch.sh) — a single bash script with `set -euo pipefail`. Steps in `install_patch` ([patch.sh:209](patch.sh#L209)):

1. `cp -R` the source app to `~/Applications/Claude-RTL.app`.
2. Replace `Contents/Resources/electron.icns` with `icon.icns` and **delete** `CFBundleIconName` from `Info.plist` — macOS prefers the asset-catalog icon over the `.icns` file unless that key is removed ([patch.sh:236](patch.sh#L236)).
3. Set `CFBundleDisplayName=Claude-RTL`. Do **not** change `CFBundleName` — Electron's fuse lookup reads `CFBundleName` and changing it breaks the fuse step ([patch.sh:246](patch.sh#L246)).
4. `asar extract` → prepend a combined header (`rtl-core.js` + an optional `@font-face` injector built by `build_font_injector`) to every `.js` file under `.vite/build/` **except the Electron main-process entry** (read from the extracted `package.json`'s `"main"` field, currently `index.pre.js`) → `asar pack`. Injecting the payload into the main process makes Electron fail to spawn any `BrowserWindow` at startup (black-screen launch); skipping that one file is the fix ([patch.sh:282](patch.sh#L282)). The injection is also skipped per-file if the `CLAUDE RTL PATCH START` marker is already present.
5. `@electron/fuses write … EnableEmbeddedAsarIntegrityValidation=off`. **Required** — Electron validates the ASAR hash at startup and the modified archive will crash the app without this.
6. `codesign --force --deep --sign - --entitlements <plist>` (ad-hoc). The original Anthropic signature is invalidated by the ASAR/fuse changes; ad-hoc signing is what lets macOS launch the modified bundle. Entitlements are extracted from `$SOURCE_APP` and re-applied — without them, runtime entitlement checks fail (notably Cowork, which calls `@ant/claude-swift`'s VM check and shows "installation appears to be corrupted" when `com.apple.security.virtualization` is missing). Three team-id-coupled keys are stripped before re-signing: `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups` — they reference Anthropic's team ID `Q6L2SF6YDW` and macOS rejects them under an ad-hoc signature ([patch.sh:338](patch.sh#L338)).

`quit_claude_rtl` ([patch.sh:110](patch.sh#L110)) is deliberately scoped to the `Claude-RTL.app` bundle path so it never touches the user's running original Claude Desktop or Claude Code CLI.

## RTL payload (rtl-core.js)

A self-contained IIFE wrapped in `// --- CLAUDE RTL PATCH START ---` / `--- END ---` markers (the start marker is what `patch.sh` greps for to skip already-patched files). Bails out early if `document` is undefined so it's safe to prepend to any renderer bundle, including ones that may run in a non-DOM context. Uses a `MutationObserver` to handle Claude's streamed responses and force-keeps `<pre>`/`<code>`/math LTR.

Key internals:
- **3-layer direction detection** (`detectTextDir` / `detectElDir`): first-strong character → strip leading LTR noise (URLs, file paths, inline-code) and re-check → fall back to RTL if any RTL char is present.
- **`WRITING_SEL`** = `[data-testid="chat-input"], .tiptap.ProseMirror` — the chat input editor(s) that get live direction switching on the `input` event.
- **`MATH_SEL`** isolates KaTeX/MathJax/MathML so equations stay LTR (`forceMathLTR` + CSS `unicode-bidi:isolate`).
- Most enforcement is CSS in `injectStyles()` (`unicode-bidi:plaintext` on block elements); the JS only sets `dir` attributes the CSS keys off of.

When editing payload behavior, **preserve the start/end marker comments** — removing them breaks idempotency. The `font-family` for RTL text is intentionally **not** set here — it's injected separately by `build_font_injector` only when the user opts in, so the family name has a single source of truth.

## RTL font (fonts/ + build_font_injector)

Font replacement is **opt-in, not on by default** — the patch leaves Claude's font alone unless the user passes `--font NAME` (or sets `RTL_FONT_FAMILY=NAME`; the `--font` flag wins when both are set). When opted in, the font is **embedded as a base64 `data:` URI**, not loaded from a CDN or a local file. This is forced by Claude's enforced CSP: the main window is `font-src 'self' data:` with `connect-src 'none'`, and the artifact-preview sandbox is `font-src data:` — so external hosts (Google Fonts/jsDelivr) are blocked and a `data:` URI is the only source that works in every context.

`build_font_injector` ([patch.sh:132](patch.sh#L132)) is a no-op when `$RTL_FONT_FAMILY` is empty. When set, it:
1. Globs `fonts/` for files **whose name starts with the family name** — `"$family"*.{woff2,woff,ttf,otf}` (case-insensitive). This prefix match is what keeps the two bundled families separate: `--font Vazirmatn` embeds only `Vazirmatn-*`, not `Estedad-*`.
2. Guesses weight/style from each filename (`-Bold`, `-Light`, `-ExtraBold`, `-Italic`, …) and base64-encodes each into an `@font-face` for the `$RTL_FONT_FAMILY` family.
3. Appends a rule applying that family to `[dir="rtl"]` and the chat input (keeping `pre`/`code` monospace), and wraps it all in a guarded IIFE (`// --- CLAUDE RTL FONT START/END ---`) on the combined header.

The family name is sanitized (quotes/backslashes stripped) before being embedded, and all generated CSS uses single quotes so it stays valid inside the double-quoted JS string literal.

Bundled fonts (Persian/Arabic, OFL — see [fonts/OFL.txt](fonts/OFL.txt)): **Vazirmatn** (`Vazirmatn-Regular/Bold`) and **Estedad** (`Estedad-Thin` … `Estedad-Black`, 9 weights). User opt-in paths (all without code edits):
- **CLI flag:** `./patch.sh --install --font Vazirmatn` (or `--font Estedad`).
- **Different bundled font:** drop `.woff2/.woff/.ttf/.otf` files into `fonts/` whose names start with the family name, then `--font "<family-name>"` — embedded, so works even if not installed system-wide.
- **Installed font, no files:** `--font "B Nazanin"` with no matching files in `fonts/` falls back to an already-installed font of that name.
- **Env var:** `RTL_FONT_FAMILY=Vazirmatn ./patch.sh --install`.

Note: Vazirmatn/Estedad cover Persian/Arabic/Latin but **not Hebrew** — Hebrew text falls through to the system Hebrew font. Hebrew users wanting a custom font should bundle one with Hebrew glyphs (Heebo, Rubik, Assistant, etc.) in `fonts/`.

## Things that will trip you up

- **Don't patch `/Applications/Claude.app`.** That bundle is root-owned and protected by macOS App Management; modifying it would require sudo and would break Anthropic's auto-updates. The "copy to `~/Applications/`" design is the whole point.
- **Claude updates ≠ patched copy updates.** Anthropic's auto-updater only updates the original. After a Claude update the user must re-run `./patch.sh --install` to rebuild the patched copy from the new version.
- **`.vite/build/` is the injection target** — if Anthropic restructures the ASAR, the script dies with a clear error (e.g. [patch.sh:270](patch.sh#L270)). That's the first place to look when a new Claude version breaks the patch.
- **Keychain re-auth is expected on first launch** of the patched copy. A different code signature ⇒ macOS asks the user to re-approve "Claude Safe Storage" access. Not a bug. A one-time blank window on first launch can also occur — also not a bug.
