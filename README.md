# IT Support Toolkit (PowerShell)

Four PowerShell scripts for the checks a service desk technician does most
often: *"my PC is slow"*, *"my disk is full"*, *"the internet isn't working"*
and *"set up this new laptop"*.

Every script is **safe by default**: the read-only ones never change anything,
and the two that do (`Clear-TempFiles`, `Install-StandardApps`) only preview
until you add `-Execute`.

| Script | What it answers | Changes the PC? |
|---|---|---|
| `Get-PCHealthReport.ps1` | Why is this PC slow or misbehaving? | No |
| `Clear-TempFiles.ps1` | How much space can I safely free? | Only with `-Execute` |
| `Test-NetworkConnectivity.ps1` | Where exactly is the connection failing? | No |
| `Install-StandardApps.ps1` | Which standard apps are missing on this laptop? | Only with `-Execute` |

## The scripts

### Get-PCHealthReport.ps1
Collects Windows version, uptime, pending restarts, CPU load, memory, disk
space, battery, last Windows update, startup programs and recent system
errors. Prints a list of **findings in plain English** (e.g. *"Drive C: is low
on space (8% free)"*, *"PC has not restarted in 21 days"*) and saves an HTML
report to the Desktop that can be attached to a ticket.

```powershell
.\scripts\Get-PCHealthReport.ps1
```

### Clear-TempFiles.ps1
Finds temp files older than a set number of days, shows the largest ones and
the total space they use, and deletes them only when asked. Files in use are
skipped, never forced.

```powershell
.\scripts\Clear-TempFiles.ps1                       # preview
.\scripts\Clear-TempFiles.ps1 -Execute              # clean user temp
.\scripts\Clear-TempFiles.ps1 -IncludeSystemTemp -Execute   # as Administrator
```

### Test-NetworkConnectivity.ps1
Tests the connection layer by layer (adapter, router, internet, DNS, HTTPS)
and stops at the first failure, so the diagnosis points to the right place
instead of guessing. Ends with suggested next steps for that specific failure.

```
[PASS] 1. Network adapter: Wi-Fi, IP 192.168.1.23, gateway 192.168.1.1, DNS 192.168.1.1
[PASS] 2. Reach router: Ping 192.168.1.1
[PASS] 3. Reach internet by IP: Ping 1.1.1.1
[FAIL] 4. DNS lookup: Could not resolve www.microsoft.com

=== Diagnosis ===
The internet is reachable, but names are not resolving (DNS problem).
```
*(example output)*

```powershell
.\scripts\Test-NetworkConnectivity.ps1
.\scripts\Test-NetworkConnectivity.ps1 -OutputPath "$env:USERPROFILE\Desktop\network.txt"
```

### Install-StandardApps.ps1
Reads a standard app list from `config\apps.json`, checks what is already
installed, and installs the rest silently with **winget**. Changing the list
means editing the JSON file, not the code.

Each entry has a winget `id` (used to install) and a `match` pattern (used to
detect it). Detection reads Windows' own installed-programs list first,
because winget can miss apps that were installed from a vendor's website.

```json
{ "name": "Google Chrome", "id": "Google.Chrome", "match": "Google Chrome*" }
```

```powershell
.\scripts\Install-StandardApps.ps1             # preview
.\scripts\Install-StandardApps.ps1 -Execute    # install missing apps
```

## Getting started

Requirements: Windows 10 or 11, Windows PowerShell 5.1 (built in) or
PowerShell 7. `Install-StandardApps.ps1` also needs winget (App Installer).

1. Download or clone this repository.
2. Open PowerShell in the repository folder.
3. Windows blocks downloaded scripts by default. Allow them for this window
   only (the setting resets when the window closes):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
4. Run any script. Every script has built-in help:
   ```powershell
   Get-Help .\scripts\Get-PCHealthReport.ps1 -Full
   ```

## Design choices

- **Preview before change.** Anything that deletes or installs shows its plan
  first and needs `-Execute`, so a mistake costs nothing.
- **Plain-English output.** Findings are written for the person reading the
  ticket, not just for the technician.
- **No hard-coded data.** The app list lives in a config file; reports go to
  the Desktop by default and can be redirected.
- **Built-in tools only.** No modules to install; works on a fresh Windows PC.

## License

MIT
