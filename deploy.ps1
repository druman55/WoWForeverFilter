[CmdletBinding()]
param(
    # Path to the WoW AddOns folder. Override with -AddOnsPath or the WOW_ADDONS_PATH env var.
    [string]$AddOnsPath = $(if ($env:WOW_ADDONS_PATH) { $env:WOW_ADDONS_PATH } else { "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns" })
)

$ErrorActionPreference = "Stop"
$addonName = "ForeverFilter"
$source = Join-Path $PSScriptRoot $addonName
$dest = Join-Path $AddOnsPath $addonName

if (-not (Test-Path $source)) { throw "Source folder not found: $source" }
if (-not (Test-Path $AddOnsPath)) { throw "AddOns folder not found: $AddOnsPath" }

# Mirror only the add-on folder (removes files in the destination that no longer exist in source).
robocopy $source $dest /MIR /NJH /NJS /NDL /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# The packager replaces @project-version@ on release; do it here for local deploys (deployed copy only).
$version = $null
$changelog = Join-Path $PSScriptRoot "CHANGELOG.md"
if (Test-Path $changelog) {
    $m = Select-String -Path $changelog -Pattern '^##\s+v?(\d[0-9A-Za-z.\-]*)' | Select-Object -First 1
    if ($m) { $version = $m.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($version)) { $version = "dev" }
$destToc = Join-Path $dest "$addonName.toc"
if (Test-Path $destToc) {
    $tocText = [System.IO.File]::ReadAllText($destToc)
    $tocText = $tocText.Replace("@project-version@", $version.Trim())
    [System.IO.File]::WriteAllText($destToc, $tocText, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "Deployed $addonName -> $dest. Type /reload in game."
$global:LASTEXITCODE = 0
