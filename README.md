# Water 4.0 — Public Release Candidate Beta v0.9.0 source disclosure

This folder is the reviewer-facing source and build disclosure for the exact
desktop artifact **Water 4.0 Integrated Public Release Candidate Beta -
v0.9.0**. It is intended to answer the Nexus security review request: what
the mod contains, how the inspectable pieces are built, and what is not
rebuildable without the game's proprietary toolchain.

Water 4.0 is a single-player mod for *The Forever Winter*. It adds an
independent Contract system, the Water Broker, water-scaled vendor stock,
Overflow Guard, and Daytime Preparation overlays. The runtime is an overlay and
UE4SS Lua integration; it does not replace the game's native quest UI.

## Quick review

1. Read [BUILD.md](BUILD.md), [DEPENDENCIES.md](DEPENDENCIES.md), and
   [COOKED_ASSET_LIMITATION.md](COOKED_ASSET_LIMITATION.md).
2. Run `node tools/tests/Test-Water4SourceDisclosure.js` from the project root,
   or run `node build/Verify-Disclosure.js` from this folder.
3. Inspect `src/runtime` for the exact Lua/INI snapshot and `src/overlay` for
   the companion source.
4. Compare the sealed candidate archive with `SOURCE_INVENTORY.md`.

No third-party prerequisite installer is included. No save, log, crash dump,
private development state, or absolute developer path belongs in this folder.

## Attribution and boundaries

Water 4.0 was developed by **Bricen120 + Codex**. The game, its cooked assets,
and its artwork remain the property of Fun Dog. This disclosure does not grant
permission to redistribute game files; see [LICENSE-ORIGIN.md](LICENSE-ORIGIN.md).
