<#
.SYNOPSIS
    Step-by-step network check that tells you WHERE a connection is failing.

.DESCRIPTION
    When a user says "the internet isn't working", the problem is usually at
    one of these layers. The script tests them in order and stops guessing
    at the first one that fails:

      1. Is there a connected network adapter with an IP address?
      2. Can we reach the router / gateway?           (local network / Wi-Fi)
      3. Can we reach the internet by IP address?      (ISP / upstream)
      4. Can we turn a name into an IP address?        (DNS)
      5. Can we open a secure web connection (443)?    (proxy / firewall)

    It then prints a plain-English diagnosis and suggested next steps.
    READ-ONLY: it changes no network settings.

.PARAMETER TestHost
    Website used for the DNS and HTTPS checks. Default www.microsoft.com.

.PARAMETER PublicIP
    Public IP address used for the internet check. Default 1.1.1.1.

.PARAMETER OutputPath
    Optional. Save the results to a text file (useful to attach to a ticket).

.EXAMPLE
    .\Test-NetworkConnectivity.ps1

.EXAMPLE
    .\Test-NetworkConnectivity.ps1 -OutputPath "$env:USERPROFILE\Desktop\network.txt"
#>

[CmdletBinding()]
param(
    [string]$TestHost = 'www.microsoft.com',
    [string]$PublicIP = '1.1.1.1',
    [string]$OutputPath
)

$results = New-Object System.Collections.Generic.List[object]

function Add-Result($Step, $Check, [bool]$Passed, $Detail) {
    $results.Add([PSCustomObject]@{
        Step   = $Step
        Check  = $Check
        Result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
        Detail = $Detail
    })
    $colour = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ('[{0}] {1}. {2}: {3}' -f $(if ($Passed) {'PASS'} else {'FAIL'}), $Step, $Check, $Detail) -ForegroundColor $colour
}

Write-Host "Running network checks on $env:COMPUTERNAME...`n" -ForegroundColor Cyan

# --- 1. Adapter and IP ------------------------------------------------------
$config = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    Select-Object -First 1

$adapterOk = [bool]$config
if ($adapterOk) {
    $ip      = ($config.IPv4Address | Select-Object -First 1).IPAddress
    $gateway = ($config.IPv4DefaultGateway | Select-Object -First 1).NextHop
    $dns     = ($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 }).ServerAddresses -join ', '
    $apipa   = $ip -like '169.254.*'   # address Windows gives itself when DHCP fails
    Add-Result 1 'Network adapter' (-not $apipa) (
        '{0}, IP {1}, gateway {2}, DNS {3}' -f $config.InterfaceAlias, $ip, $gateway, $dns)
    if ($apipa) { $adapterOk = $false }
} else {
    Add-Result 1 'Network adapter' $false 'No connected adapter with a gateway found'
}

# --- 2-5. Each layer, only if the previous one passed ------------------------
$gatewayOk = $internetOk = $dnsOk = $httpsOk = $false

if ($adapterOk) {
    $gatewayOk = Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
    Add-Result 2 'Reach router' $gatewayOk "Ping $gateway"
}

if ($gatewayOk) {
    $internetOk = Test-Connection -ComputerName $PublicIP -Count 2 -Quiet -ErrorAction SilentlyContinue
    Add-Result 3 'Reach internet by IP' $internetOk "Ping $PublicIP"
}

if ($internetOk) {
    try {
        $resolved = Resolve-DnsName -Name $TestHost -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } | Select-Object -First 1
        $dnsOk = [bool]$resolved
        Add-Result 4 'DNS lookup' $dnsOk "$TestHost -> $($resolved.IPAddress)"
    } catch {
        Add-Result 4 'DNS lookup' $false "Could not resolve $TestHost"
    }
}

if ($dnsOk) {
    $httpsOk = Test-NetConnection -ComputerName $TestHost -Port 443 `
        -InformationLevel Quiet -WarningAction SilentlyContinue
    Add-Result 5 'Secure web (HTTPS)' $httpsOk "$TestHost port 443"
}

# --- Diagnosis --------------------------------------------------------------
if (-not $adapterOk) {
    $diagnosis = 'Not connected to a network, or the network did not give this PC an address.'
    $nextSteps = @(
        'Check Wi-Fi is on and connected, or the network cable is plugged in.',
        'Run: ipconfig /release  then  ipconfig /renew',
        'Restart the PC. If other devices are also offline, restart the router.')
} elseif (-not $gatewayOk) {
    $diagnosis = 'Connected to a network but cannot reach the router.'
    $nextSteps = @(
        'Move closer to the Wi-Fi access point or try a cable.',
        'Forget the Wi-Fi network and reconnect.',
        'Restart the router if other devices have the same problem.')
} elseif (-not $internetOk) {
    $diagnosis = 'The local network works, but there is no route to the internet.'
    $nextSteps = @(
        'Check whether other devices on the same network are online.',
        'Restart the router / modem.',
        'If the whole office is affected, escalate to the network team or ISP.')
} elseif (-not $dnsOk) {
    $diagnosis = 'The internet is reachable, but names are not resolving (DNS problem).'
    $nextSteps = @(
        'Run: ipconfig /flushdns',
        'Check the DNS servers listed in step 1 are correct for this network.',
        'Try again on another network to confirm.')
} elseif (-not $httpsOk) {
    $diagnosis = 'DNS works, but secure web connections are blocked.'
    $nextSteps = @(
        'Check proxy settings: Settings > Network & internet > Proxy.',
        'A firewall, VPN or security software may be blocking port 443.',
        'Check the PC date and time are correct (wrong time breaks HTTPS).')
} else {
    $diagnosis = 'All checks passed. The network connection looks healthy.'
    $nextSteps = @(
        'If one website still fails, the problem is likely that site or the browser.',
        'Try another browser, or clear the browser cache.')
}

Write-Host "`n=== Diagnosis ===" -ForegroundColor Yellow
Write-Host $diagnosis
Write-Host "`nSuggested next steps:" -ForegroundColor Yellow
$nextSteps | ForEach-Object { Write-Host " - $_" }

# --- Optional file output ---------------------------------------------------
if ($OutputPath) {
    $text = @(
        "Network check: $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))",
        '',
        ($results | Format-Table -AutoSize | Out-String).TrimEnd(),
        '',
        "Diagnosis: $diagnosis",
        'Next steps:',
        ($nextSteps | ForEach-Object { " - $_" })
    )
    $text | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "`nSaved to: $OutputPath" -ForegroundColor Green
}
