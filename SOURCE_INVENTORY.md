# Source and artifact inventory

The authoritative runtime snapshot is copied from the v0.9.0 candidate under
`src/runtime/Root/Windows/ForeverWinter/Binaries/Win64/ue4ss/Mods`. It contains
97 Lua files, two INI files, and one text manifest. The source tree preserves
the candidate's relative mod paths.

`src/overlay/FWQuestOverlay` contains the Contract/Water Broker companion source
and a disclosure build adapter. `src/overlay/WaterDaytimePreparationOverlay`
contains the Daytime Preparation companion source and a disclosure build
adapter. Production artwork is intentionally outside this tree; see
`assets/README.md`.

The release candidate also contains two overlay executables and the cooked
WaterOverflowGuard payload. Their hashes belong in the sealed candidate's
release manifest; they are not claimed to be rebuilt by the disclosure build.

`FILE_MANIFEST.sha256` covers the 122 disclosed files (excluding the manifest
itself) and is regenerated only when the disclosure contents intentionally
change.

Authoritative candidate ZIP SHA-256:

`740B97E1FBF539CEE22698696A6B174CFCD733C83FCF6666EC953A5B1DB4A0F2`
