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

Write-Host "Deployed $addonName -> $dest. Type /reload in game."
$global:LASTEXITCODE = 0
