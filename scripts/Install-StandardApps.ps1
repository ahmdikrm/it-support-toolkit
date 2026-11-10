<#
.SYNOPSIS
    Sets up a new Windows PC with a standard list of apps using winget.

.DESCRIPTION
    Reads the list of apps from config\apps.json and, for each one:
      - checks whether it is already installed
      - installs it silently if it is missing

    Safe by default: without -Execute it only shows what WOULD be installed.
    Edit config\apps.json to change the list; no code changes needed.

    Requires winget (App Installer), included with Windows 10 (1809+) and 11.

.PARAMETER AppListPath
    Path to the JSON app list. Defaults to ..\config\apps.json next to this script.

.PARAMETER Execute
    Actually install the missing apps. Without this switch the script only previews.

.EXAMPLE
    .\Install-StandardApps.ps1
    Preview which apps are missing.

.EXAMPLE
    .\Install-StandardApps.ps1 -Execute
    Install every missing app from the list.
#>

[CmdletBinding()]
param(
    [string]$AppListPath = (Join-Path $PSScriptRoot '..\config\apps.json'),

    [switch]$Execute
)

# --- Checks before starting -------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error 'winget was not found. Install "App Installer" from the Microsoft Store, then try again.'
    exit 1
}

if (-not (Test-Path $AppListPath)) {
    Write-Error "App list not found: $AppListPath"
    exit 1
}

$apps = Get-Content -Path $AppListPath -Raw | ConvertFrom-Json
if (-not $apps) {
    Write-Error "No apps listed in $AppListPath"
    exit 1
}

$mode = if ($Execute) { 'INSTALL' } else { 'PREVIEW (nothing will be installed)' }
Write-Host "Mode: $mode" -ForegroundColor Cyan
Write-Host "Apps in list: $(@($apps).Count)`n"

# --- Read the list of installed programs once --------------------------------
# This is the same list Windows shows in Settings > Apps. It is more reliable
# than asking winget, because winget only recognises apps it can match to its
# catalogue (e.g. it may miss Chrome if Chrome was installed from google.com).
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedNames = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object -ExpandProperty DisplayName

function Test-AppInstalled($App) {
    # 1. Installed-programs list, matched by display name (e.g. "Google Chrome*").
    if ($App.match -and ($installedNames | Where-Object { $_ -like $App.match })) {
        return $true
    }
    # 2. Fall back to winget, for apps it does recognise.
    $output = winget list --id $App.id --exact --accept-source-agreements 2>&1 | Out-String
    return ($LASTEXITCODE -eq 0) -or ($output -match [regex]::Escape($App.id))
}

# --- Check and install each app ---------------------------------------------
$results = foreach ($app in $apps) {
    Write-Host "Checking $($app.name)..." -NoNewline

    $installed = Test-AppInstalled $app

    if ($installed) {
        Write-Host ' already installed' -ForegroundColor DarkGray
        $status = 'Already installed'
    } elseif (-not $Execute) {
        Write-Host ' missing (would install)' -ForegroundColor Yellow
        $status = 'Would install'
    } else {
        Write-Host ' installing...' -ForegroundColor Yellow -NoNewline
        winget install --id $app.id --exact --silent `
            --accept-package-agreements --accept-source-agreements *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ' done' -ForegroundColor Green
            $status = 'Installed'
        } else {
            Write-Host " failed (code $LASTEXITCODE)" -ForegroundColor Red
            $status = "Failed (code $LASTEXITCODE)"
        }
    }

    [PSCustomObject]@{ App = $app.name; 'winget ID' = $app.id; Status = $status }
}

# --- Summary ----------------------------------------------------------------
Write-Host "`n=== Summary ===" -ForegroundColor Yellow
$results | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Execute) {
    Write-Host 'Nothing was installed. Run again with -Execute to install missing apps.' -ForegroundColor Green
}
