<#
.SYNOPSIS
    Finds and (optionally) deletes old temporary files to free disk space.

.DESCRIPTION
    Safe by default: without -Execute it only shows what WOULD be deleted
    and how much space would be freed. Nothing is removed until you run it
    again with -Execute.

    Only files older than -OlderThanDays are touched, so files that programs
    are using right now are left alone. Files that are locked are skipped,
    never forced.

    Locations cleaned:
      - The current user's temp folder (%TEMP%)
      - The Windows temp folder (C:\Windows\Temp), only with -IncludeSystemTemp
        and only when running as Administrator

.PARAMETER OlderThanDays
    Only include files not modified for this many days. Default 2.

.PARAMETER IncludeSystemTemp
    Also clean C:\Windows\Temp (requires Administrator).

.PARAMETER Execute
    Actually delete the files. Without this switch the script only previews.

.EXAMPLE
    .\Clear-TempFiles.ps1
    Preview only.

.EXAMPLE
    .\Clear-TempFiles.ps1 -Execute
    Delete old files from the user's temp folder.

.EXAMPLE
    .\Clear-TempFiles.ps1 -IncludeSystemTemp -OlderThanDays 7 -Execute
    Run as Administrator. Also cleans the Windows temp folder.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 365)]
    [int]$OlderThanDays = 2,

    [switch]$IncludeSystemTemp,

    [switch]$Execute
)

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# --- Decide which folders to clean ------------------------------------------
# Resolve %TEMP% to its full path (it can be a short name like AHMADS~1).
$targets = @((Get-Item -LiteralPath $env:TEMP).FullName)

if ($IncludeSystemTemp) {
    if (Test-IsAdmin) {
        $targets += (Join-Path $env:SystemRoot 'Temp')
    } else {
        Write-Warning 'Skipping C:\Windows\Temp: run PowerShell as Administrator to include it.'
    }
}

$cutoff = (Get-Date).AddDays(-$OlderThanDays)
$mode   = if ($Execute) { 'DELETE' } else { 'PREVIEW (nothing will be deleted)' }
Write-Host "Mode: $mode" -ForegroundColor Cyan
Write-Host "Files older than: $($cutoff.ToString('yyyy-MM-dd HH:mm'))`n"

$summary = foreach ($folder in $targets) {
    if (-not (Test-Path $folder)) { continue }

    $files = @(Get-ChildItem -Path $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -lt $cutoff })

    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }

    $deleted = 0; $freed = 0; $skipped = 0

    if ($Execute) {
        foreach ($file in $files) {
            try {
                $size = $file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deleted++; $freed += $size
            } catch {
                $skipped++   # file is in use or protected; leave it alone
            }
        }

        # Remove folders left empty by the clean-up (deepest first).
        Get-ChildItem -Path $folder -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host "Largest old files in ${folder}:" -ForegroundColor Yellow
        $files | Sort-Object Length -Descending | Select-Object -First 10 |
            Format-Table @{n='Size'; e={Format-Size $_.Length}},
                         @{n='Last modified'; e={$_.LastWriteTime.ToString('yyyy-MM-dd')}},
                         @{n='File'; e={$_.FullName}} -AutoSize |
            Out-String | Write-Host
    }

    [PSCustomObject]@{
        'Folder'      = $folder
        'Old files'   = $files.Count
        'Old size'    = Format-Size $totalBytes
        'Deleted'     = $(if ($Execute) { $deleted } else { '-' })
        'Freed'       = $(if ($Execute) { Format-Size $freed } else { '-' })
        'Skipped (in use)' = $(if ($Execute) { $skipped } else { '-' })
    }
}

Write-Host '=== Summary ===' -ForegroundColor Yellow
$summary | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Execute) {
    Write-Host 'Nothing was deleted. Run again with -Execute to clean up.' -ForegroundColor Green
}
