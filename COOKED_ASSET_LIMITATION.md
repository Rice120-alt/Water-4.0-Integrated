# Cooked Unreal asset limitation

The candidate ZIP includes `105-WaterOverflowGuard_P.pak`, its `.ucas`, and its
`.utoc` companion. These are cooked Unreal assets required by the game-facing
Overflow Guard integration.

They are **not reproducible from this source disclosure**. Exact regeneration
requires Fun Dog's proprietary Unreal project, editor version, source assets,
cook configuration, and signing/layout details. A normal .NET, PowerShell, or
UE4SS build cannot recreate them. The disclosure therefore provides the
inspectable Lua policy and the hash manifest for the prebuilt payload while
stating this boundary explicitly.
