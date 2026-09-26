# FW Quest Overlay, Contract Board, and Water Broker

This .NET 8 WinForms companion consumes the independent framework's primitive
`fwif.contracts.overlay.v1` and `fwif.water_vendor.overlay.v1` snapshots. It does
not inject into the game process and never receives or retains an Unreal object.
The companion presents state and writes narrowly validated requests; the Lua
framework remains the sole gameplay/economy authority.

The companion has four presentation modes:

- `hub_operations_launcher`: small clickable CONTRACTS and WATER BROKER entries,
  each enabled only when its framework snapshot reports the exact Innards hub;
- `hub_contract_board`: an interactive list/details surface with mouse-driven
  selectable multi-Contract entries and per-entry accept/discard controls;
- `hub_water_trader`: an indexed rotating-offer storefront with a detailed exact
  quote and mandatory review/confirm clicks before a purchase request is written;
- `raid_tracker`: an adaptive, highly translucent, click-through stack of all
  active Contracts, positioned immediately left of the native quest-HUD lane.

The launcher is exact-HUB gated, not native-menu gated. Whether
`WBP_MenuMaster_C` is open remains unknown and is intentionally not guessed.
The board uses the same session-bound, monotonic command file as the verified
F9/F8 flow and dispatches the currently selected `contract_id`.

Companion v0.30.2 measures each raid-card title against its actual content
width and reduces only titles that would overflow. Drawing is clipped to that
same single-line region as a final guard, so long Contract names cannot cross
the panel edge while ordinary short names keep the established size. The
midraid tracker now renders accepted, active Contracts only and hides completely
when the player enters a raid without one.

Companion v0.30.3 defers the game-window focus request until after the
mouse-up or Escape dispatch closes a Contract/Broker surface, explicitly
releases overlay mouse capture, and logs the Windows foreground handoff.
The live effect on cursor/control recapture still needs an attended test.

The Water Broker state and command channels are deliberately separate from the
Contract channels. With no extra arguments they are auto-detected beside the
Contract state under `water-trader/overlay-v1.txt` and
`water-trader/command-v1.txt`. A vendor-only launch using the existing
`--state .../water-trader/overlay-v1.txt --command .../water-trader/command-v1.txt`
shape is schema/path-detected and routed to the same separate channels.
Selection/purchase requests use
`fwif.water_vendor.command.v1` and echo the exact session, snapshot revision,
rotation, offer, stock, readiness, cost, quantity, and quote fingerprint shown
to the user. A newly written request disables purchase input until a newer
framework snapshot arrives, preventing the single-file command channel from
being overwritten before consumption.

Companion v0.26.0 keeps offer cards clickable while an unconfirmed Water Broker
quote is open. Clicking a different card replaces the quote without Cancel;
clicking the same card preserves its chosen quantity. Card browsing is local
presentation state and does not write a framework command. Only the separate
Confirm action writes a purchase request, after which card input remains locked
until the newer authoritative snapshot arrives. Its interaction/repaint cadence
is 25 ms, while snapshot and game-window polling remain throttled to 100 ms so
the responsiveness improvement does not multiply file or process scans. The
quote shows only purchase units, received quantity, and Water cost; redundant
stock-after and max-affordable rows are omitted. Stock remains visible on each
card and the `MAX` quantity control remains authoritative. The lower details
section is labelled `LATEST PURCHASE` and shows the committed item quantity and
Water amount without exposing the internal transaction-status code.

Companion v0.28.0 derives restricted-market text from the snapshot's configured
weapon/special permissions and unlock thresholds. It no longer owns a literal
`66+` requirement. Its existing countdown renders the Broker's fixed
wall-clock deadline, which defaults to local midnight, 2 AM, 4 AM, and so on.

Broker input-state writes are independent from purchase-command readiness, so
a transaction or durability block cannot cut off the visible surface's
heartbeat. The existing exact-HUB controller lease suppresses movement and
camera. A Broker-only low-level keyboard guard additionally consumes Space,
Left/Right Ctrl, C, and Escape only while the game or overlay is foreground.
Escape is redirected into the Broker's balanced close/release path instead of
opening the game pause menu. The action-key guard is **UNTESTED-LIVE**.

Controls:

- F7 or CONTRACTS launcher click: open/close the Contract Board;
- WATER BROKER launcher click: open the storefront;
- offer click: select an indexed offer and open its focused transaction dialog
  after the non-mutating selection request is echoed by the framework;
- `-`, `+`, or `MAX`: choose bundle units within current stock and Water;
- CONFIRM EXCHANGE: submit the separately confirmed displayed exact quote;
- Escape: close the current hub surface;
- board button or F9: accept;
- board button or F8: discard;
- F10: hide/show the companion.

Optional paths are `--vendor-state <path>` and `--vendor-command <path>`.
The isolated Water Broker package also passes `--vendor-only`; in that mode the
companion does not read Contract state or expose Contract controls, so a stale
Contract raid snapshot cannot suppress the hub storefront. The legacy
vendor-state launch shape infers this isolation mode automatically.
The Contract runtime passes `--contracts-only`; in that mode the companion does
not read or expose a Water Broker snapshot. This prevents a stale snapshot from
a disabled trader package from creating a launcher or storefront in the
Contract-only experiment. A future intentionally combined surface must opt into
both channels explicitly instead of inheriting stale files.
The strict storefront parser caps input at 64 KiB/eight offers and rejects
malformed percent escapes, unknown or duplicate keys, duplicate offer IDs,
invalid numeric/boolean fields, and mismatched authoritative selection fields.

Build, self-test, and previews:

```powershell
dotnet publish .\FWQuestOverlay.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
.\bin\Release\net8.0-windows\win-x64\publish\FWQuestOverlay.exe --self-test
.\bin\Release\net8.0-windows\win-x64\publish\FWQuestOverlay.exe --render-preview .\raid-preview.png
.\bin\Release\net8.0-windows\win-x64\publish\FWQuestOverlay.exe --render-hub-preview .\launcher-preview.png
.\bin\Release\net8.0-windows\win-x64\publish\FWQuestOverlay.exe --render-board-preview .\board-preview.png
.\bin\Release\net8.0-windows\win-x64\publish\FWQuestOverlay.exe --render-trader-preview .\trader-preview.png
```

MO2 requirement: `executable_blacklist` must include both `cmd.exe` and
`FWQuestOverlay.exe` in a quoted semicolon-delimited value.

Evidence: v0.5.1 visibility and redraw are **VERIFIED-CURRENT**. v0.6.0's hub
gate, F7 receipt, mode changes, and Win32 render calls executed live, but its
hub launcher and board were invisible to the user. Removing `WS_EX_NOACTIVATE`
for interactive modes is **FAILED/DISPROVEN** for that display. v0.6.1 keeps
the non-activating style in every mode, toggles only click-through, reasserts
topmost z-order, and emits explicit style/visibility diagnostics. v0.6.1
visibility, mouse selection, command dispatch, one-Water debit, and discard are
**VERIFIED-CURRENT** in `2026-09-03_235502...`. v0.7.0 multi-Contract behavior
is **VERIFIED-CURRENT** in `2026-09-04_005245...`. The v0.11.0 Water Broker
parser, layout, hit targets, and command serialization have deterministic local
self-test coverage. v0.0.33's storefront rotation and selection are
**VERIFIED-CURRENT**; v0.0.36's one-bundle purchase request and exact 30-round
native composition are **VERIFIED-CURRENT**. v0.0.37's quantity controls and
expanded ordinary-item routes are **VERIFIED-CURRENT (offline only)** and
**HYPOTHESIS** live; its absent version-directory packaging is
**FAILED/DISPROVEN**. v0.0.38 adds verified-before-use runtime-directory
creation without changing the Broker UI. Contract v0.0.39's full-client board,
three-card selection, exact 2-Water fee, and seven balanced input cycles are
**VERIFIED-CURRENT**. Overlay v0.14.0 preserves compact counters and Contract
Fee wording while using the v0.0.40 live `5120x1440` screenshot to place the
raid tracker substantially closer to the native quest-HUD lane. The revised
placement remains **UNTESTED-LIVE**.
