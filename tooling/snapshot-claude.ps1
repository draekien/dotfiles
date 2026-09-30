param(
    [string]$Source = (Join-Path $HOME '.claude'),
    [string]$Destination = (Join-Path (Split-Path $PSScriptRoot -Parent) '.claude')
)

$ErrorActionPreference = 'Stop'

$excludedKeys = '@synced$'

function Remove-ExcludedKeys($node) {
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($name in @($node.PSObject.Properties.Name)) {
            if ($name -match $excludedKeys) { $node.PSObject.Properties.Remove($name) }
            else { Remove-ExcludedKeys $node.$name }
        }
    } elseif ($node -is [array]) {
        foreach ($item in $node) { Remove-ExcludedKeys $item }
    }
}

New-Item -ItemType Directory -Force $Destination | Out-Null

foreach ($file in 'CLAUDE.md', 'settings.json') {
    Copy-Item -LiteralPath (Join-Path $Source $file) -Destination (Join-Path $Destination $file) -Force
}

$settingsPath = Join-Path $Destination 'settings.json'
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
Remove-ExcludedKeys $settings
Set-Content $settingsPath -Value ($settings | ConvertTo-Json -Depth 100) -Encoding utf8NoBOM

$hooks = Join-Path $Destination 'hooks'
if (Test-Path $hooks) { Remove-Item $hooks -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $Source 'hooks') -Destination $hooks -Recurse
