<#
.SYNOPSIS
    Creates a one-page health report for a Windows PC.

.DESCRIPTION
    Collects the details a service desk technician usually checks first when a
    user says "my computer is slow" or "something is wrong with my laptop":

      - Windows version, uptime and pending restarts
      - CPU load, memory use and free disk space
      - Battery health (laptops)
      - Last installed Windows update
      - Programs that start automatically
      - Recent critical / error events in the System log

    The script is READ-ONLY. It changes nothing on the machine.
    Results are printed to the screen and saved as an HTML report.

.PARAMETER OutputPath
    Where to save the HTML report. Defaults to the Desktop.

.PARAMETER DiskWarnPercent
    Warn when a drive has less free space than this percentage. Default 15.

.EXAMPLE
    .\Get-PCHealthReport.ps1

.EXAMPLE
    .\Get-PCHealthReport.ps1 -OutputPath C:\Reports\pc.html -DiskWarnPercent 20
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) (
        'PCHealth_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm'))),

    [ValidateRange(1, 90)]
    [int]$DiskWarnPercent = 15
)

$ErrorActionPreference = 'Stop'
$findings = New-Object System.Collections.Generic.List[string]

Write-Host "Collecting health information for $env:COMPUTERNAME..." -ForegroundColor Cyan

# --- System and uptime ------------------------------------------------------
$os     = Get-CimInstance Win32_OperatingSystem
$cs     = Get-CimInstance Win32_ComputerSystem
$uptime = (Get-Date) - $os.LastBootUpTime

if ($uptime.TotalDays -gt 14) {
    $findings.Add(("PC has not restarted in {0} days. A restart often fixes slowness and finishes updates." -f [int]$uptime.TotalDays))
}

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
$rebootPending = [bool]($rebootKeys | Where-Object { Test-Path $_ })
if ($rebootPending) {
    $findings.Add('A restart is pending to finish installing updates.')
}

$system = [PSCustomObject]@{
    'Computer'       = $env:COMPUTERNAME
    'User'           = $env:USERNAME
    'Model'          = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
    'Windows'        = ('{0} (build {1})' -f $os.Caption, $os.BuildNumber)
    'Last restart'   = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
    'Uptime'         = ('{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
    'Restart needed' = $(if ($rebootPending) { 'Yes' } else { 'No' })
}

# --- CPU and memory ---------------------------------------------------------
$cpu     = Get-CimInstance Win32_Processor
$cpuLoad = [int](($cpu | Measure-Object -Property LoadPercentage -Average).Average)

$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)   # value is in KB
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$usedPct = [int](100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))

if ($cpuLoad -gt 85) { $findings.Add("CPU is busy ($cpuLoad%). Check Task Manager for a program using it.") }
if ($usedPct -gt 85) { $findings.Add("Memory is $usedPct% used. Closing browser tabs or programs may help.") }

$performance = [PSCustomObject]@{
    'CPU'         = ($cpu | Select-Object -First 1).Name.Trim()
    'CPU load'    = "$cpuLoad%"
    'Memory'      = "$totalGB GB total, $freeGB GB free ($usedPct% used)"
}

# --- Disks ------------------------------------------------------------------
# Skip cloud "virtual drives" (e.g. Google Drive for desktop). They report the
# local disk's free space as their own, which would cause a false warning.
$disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
    Where-Object { $_.VolumeName -notmatch 'Google Drive' } |
    ForEach-Object {
    $freePct = if ($_.Size) { [int]($_.FreeSpace / $_.Size * 100) } else { 0 }
    if ($freePct -lt $DiskWarnPercent) {
        $findings.Add(("Drive {0} is low on space ({1}% free). Try Clear-TempFiles.ps1." -f $_.DeviceID, $freePct))
    }
    [PSCustomObject]@{
        'Drive'   = $_.DeviceID
        'Size GB' = [math]::Round($_.Size / 1GB, 1)
        'Free GB' = [math]::Round($_.FreeSpace / 1GB, 1)
        'Free %'  = $freePct
    }
}

# --- Battery (laptops only) -------------------------------------------------
$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        'Charge %' = $_.EstimatedChargeRemaining
        'Status'   = switch ($_.BatteryStatus) {
                         1 { 'On battery' } 2 { 'Plugged in' } 3 { 'Fully charged' }
                         default { "Code $($_.BatteryStatus)" } }
    }
}

# --- Windows Update ---------------------------------------------------------
$lastUpdate = Get-HotFix -ErrorAction SilentlyContinue |
    Where-Object { $_.InstalledOn } |
    Sort-Object InstalledOn -Descending |
    Select-Object -First 1

if ($lastUpdate) {
    $daysSince = [int]((Get-Date) - $lastUpdate.InstalledOn).TotalDays
    if ($daysSince -gt 45) {
        $findings.Add("Last Windows update was $daysSince days ago. Check Windows Update.")
    }
    $updateInfo = '{0} on {1} ({2} days ago)' -f $lastUpdate.HotFixID,
        $lastUpdate.InstalledOn.ToString('yyyy-MM-dd'), $daysSince
} else {
    $updateInfo = 'Could not read update history'
}
$performance | Add-Member -NotePropertyName 'Last update' -NotePropertyValue $updateInfo

# --- Startup programs -------------------------------------------------------
$startup = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
    Select-Object @{n='Program'; e={$_.Name}}, @{n='Location'; e={$_.Location}} |
    Sort-Object Program

if (@($startup).Count -gt 15) {
    $findings.Add(("{0} programs start with Windows. Disabling some in Task Manager > Startup can speed up login." -f @($startup).Count))
}

# --- Recent problems in the System log --------------------------------------
$events = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Level     = 1, 2                      # 1 = Critical, 2 = Error
        StartTime = (Get-Date).AddDays(-7)
    } -MaxEvents 10 -ErrorAction SilentlyContinue |
    Select-Object @{n='Time';   e={$_.TimeCreated.ToString('yyyy-MM-dd HH:mm')}},
                  @{n='Level';  e={$_.LevelDisplayName}},
                  @{n='Source'; e={$_.ProviderName}},
                  @{n='Message';e={ ($_.Message -split "`n")[0].Trim() }}

if (-not $findings.Count) { $findings.Add('No problems found.') }

# --- Screen output ----------------------------------------------------------
Write-Host "`n=== Findings ===" -ForegroundColor Yellow
$findings | ForEach-Object { Write-Host " - $_" }

Write-Host "`n=== System ===" -ForegroundColor Yellow
$system | Format-List | Out-String | Write-Host
Write-Host "=== Performance ===" -ForegroundColor Yellow
$performance | Format-List | Out-String | Write-Host
Write-Host "=== Disks ===" -ForegroundColor Yellow
$disks | Format-Table -AutoSize | Out-String | Write-Host

# --- HTML report ------------------------------------------------------------
$style = @'
<style>
 body  { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
 h1    { font-size: 20px; } h2 { font-size: 16px; margin-top: 24px; }
 table { border-collapse: collapse; margin-bottom: 8px; }
 th,td { border: 1px solid #ccc; padding: 4px 10px; text-align: left; font-size: 13px; }
 th    { background: #f0f0f0; }
 li    { margin: 4px 0; }
</style>
'@

function ConvertTo-Section($Title, $Data, [switch]$List) {
    if (-not $Data) { return "<h2>$Title</h2><p>None</p>" }
    $as = if ($List) { 'List' } else { 'Table' }
    return "<h2>$Title</h2>" + ($Data | ConvertTo-Html -Fragment -As $as | Out-String)
}

$findingsHtml = ($findings | ForEach-Object {
    '<li>' + [System.Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join ''

$body = @(
    "<h1>PC health report: $env:COMPUTERNAME</h1>",
    "<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>",
    "<h2>Findings</h2><ul>$findingsHtml</ul>",
    (ConvertTo-Section 'System'           $system -List),
    (ConvertTo-Section 'Performance'      $performance -List),
    (ConvertTo-Section 'Disks'            $disks),
    (ConvertTo-Section 'Battery'          $battery),
    (ConvertTo-Section 'Startup programs' $startup),
    (ConvertTo-Section 'Recent system errors (7 days)' $events)
) -join "`n"

ConvertTo-Html -Title "PC health - $env:COMPUTERNAME" -Head $style -Body $body |
    Out-File -FilePath $OutputPath -Encoding utf8

Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
