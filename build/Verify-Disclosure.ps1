param([string]$DisclosureRoot = (Split-Path -Parent $PSScriptRoot))
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
& node (Join-Path $repo 'tools\tests\Test-Water4SourceDisclosure.js') $DisclosureRoot
if ($LASTEXITCODE -ne 0) { throw "Water 4.0 source disclosure validation failed ($LASTEXITCODE)." }
Write-Host "Water 4.0 source disclosure validation passed: $DisclosureRoot"
