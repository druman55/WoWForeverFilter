[CmdletBinding()]
param(
    # Which installs to deploy to: retail (default), forever, or all. Installs that don't exist are skipped with "all".
    [ValidateSet("all", "retail", "forever")]
    [string]$Flavor = "retail",
    # Explicit AddOns folder. Overrides -Flavor. Can also be set with the WOW_ADDONS_PATH env var.
    [string]$AddOnsPath = $env:WOW_ADDONS_PATH,
    # WoW install root used with -Flavor.
    [string]$WowRoot = "C:\Program Files (x86)\World of Warcraft"
)

$ErrorActionPreference = "Stop"
$addonName = "ForeverFilter"
$source = Join-Path $PSScriptRoot $addonName
if (-not (Test-Path $source)) { throw "Source folder not found: $source" }

# The packager replaces @project-version@ on release; do it here for local deploys (deployed copy only).
$version = $null
$changelog = Join-Path $PSScriptRoot "CHANGELOG.md"
if (Test-Path $changelog) {
    $m = Select-String -Path $changelog -Pattern '^##\s+v?(\d[0-9A-Za-z.\-]*)' | Select-Object -First 1
    if ($m) { $version = $m.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($version)) { $version = "dev" }

$targets = @()
if (-not [string]::IsNullOrWhiteSpace($AddOnsPath)) {
    if (-not (Test-Path $AddOnsPath)) { throw "AddOns folder not found: $AddOnsPath" }
    $targets += $AddOnsPath
} else {
    $folders = @{ retail = "_retail_"; forever = "_forever_" }
    $names = if ($Flavor -eq "all") { @("retail", "forever") } else { @($Flavor) }
    foreach ($n in $names) {
        $path = Join-Path $WowRoot (Join-Path $folders[$n] "Interface\AddOns")
        if (Test-Path $path) {
            $targets += $path
        } elseif ($Flavor -ne "all") {
            throw "AddOns folder not found: $path"
        } else {
            Write-Host "Skipping $n (not installed): $path"
        }
    }
}
if ($targets.Count -eq 0) { throw "No WoW AddOns folder found under $WowRoot" }

foreach ($target in $targets) {
    $dest = Join-Path $target $addonName
    # Mirror only the add-on folder (removes files in the destination that no longer exist in source).
    robocopy $source $dest /MIR /NJH /NJS /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE for $dest" }
    $destToc = Join-Path $dest "$addonName.toc"
    if (Test-Path $destToc) {
        $tocText = [System.IO.File]::ReadAllText($destToc)
        $tocText = $tocText.Replace("@project-version@", $version.Trim())
        [System.IO.File]::WriteAllText($destToc, $tocText, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "Deployed $addonName v$version -> $dest"
}
Write-Host "Type /reload in game."
$global:LASTEXITCODE = 0