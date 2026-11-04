#Requires -Version 5.1
<#
.SYNOPSIS
    After the WinPE run, checks that the VirtIO drivers are installed, then saves the
    IPv4 configuration of a server before the VMware -> KVM migration and places
    a script on the server that restores it after the migration.

.DESCRIPTION
    Runs on the jump host and connects to the server via PowerShell Remoting (WinRM).
    Does not change the server's network settings. On the server: removes the registry subkey
    StartOverride for viostor/vioscsi (section 0), places the restore script and a
    scheduled task (section 3).

    When: AFTER the WinPE run (server is running on VMware again), BEFORE the migration.
    First a VirtIO check: C:\virtio-inject\completed.txt exists, viostor/vioscsi have Start=0
    and no StartOverride, netkvm is in the driver store. If the check fails: abort, nothing
    is placed, NO migration (the VM would not boot on KVM or would have no network).
    If the VM reboots on VMware once more before the migration (e.g. Windows Update), the
    scheduled task removes StartOverride again.

    Reads the ONE network adapter: IP address(es) with prefix, gateway,
    DNS servers, DNS suffix and "Register this connection's addresses in DNS".
    Aborts if the server does not have exactly one physical adapter or if it is not up.
    DHCP: nothing to save, only a notice (VirtIO check ok, migration possible).

    Result:
      - on the server:    C:\virtio-inject\Restore-NetConfig.ps1
                          + scheduled task "VirtIO-Restore-NetConfig" (at startup, as SYSTEM)
      - on the jump host: copy in the folder NetConfig next to this script
        (if the VM does not come up after the migration, the values are still available)

    After the migration the restore script runs automatically on the first start on the target hypervisor:
    sets the IP, then deletes the task and itself (the log stays:
    C:\virtio-inject\Restore-NetConfig.log). If the VM still starts on VMware (e.g. after a
    rollback of the migration), it exits without changes and tries again at the next start.
    Running it manually still works (console of the target hypervisor, as administrator):
      powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1

.PARAMETER ComputerName
    Server whose configuration is saved.
.PARAMETER Credential
    Optional. Without it the logged-on account is used.
.PARAMETER LocalCopyPath
    Folder for the copy on the jump host (default: subfolder NetConfig next to the script).

.EXAMPLE
    .\Export-NetConfig.ps1 -ComputerName SRV01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$LocalCopyPath
)

$ErrorActionPreference = 'Stop'

$remote = @{ ComputerName = $ComputerName }
if ($Credential) { $remote.Credential = $Credential }

# ----------------------------------------------------------------------------
# 0. VirtIO check: did the WinPE run install the drivers?
#    A Windows logon alone does not prove that (the key press at CD boot was missed,
#    reboot after an error).
#    StartOverride: Windows disables a boot driver if it finds no hardware at startup -
#    so always when booting on VMware. If the registry key remained, viostor/vioscsi would be disabled
#    on the first start on KVM -> blue screen 0x7B. So remove it here (the Xen PV
#    drivers do the same: https://lists.xenproject.org/archives/html/win-pv-devel/2021-06/msg00030.html).
# ----------------------------------------------------------------------------
Write-Host "Checking VirtIO drivers on $ComputerName ..."

$chk = Invoke-Command @remote -ScriptBlock {
    $svc = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $r = [ordered]@{ Completed = Test-Path 'C:\virtio-inject\completed.txt' }
    foreach ($s in 'viostor', 'vioscsi') {
        $r["${s}Start"]   = [string](Get-ItemProperty "$svc\$s" -ErrorAction SilentlyContinue).Start
        $r["${s}Removed"] = $false
        if (Test-Path "$svc\$s\StartOverride") {
            Remove-Item "$svc\$s\StartOverride" -Recurse -Force -ErrorAction SilentlyContinue
            $r["${s}Removed"] = $true
        }
        $r["${s}Override"] = Test-Path "$svc\$s\StartOverride"
    }
    $r.NetKvm = [bool](Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'netkvm.inf_*' -ErrorAction SilentlyContinue)
    # An execution policy set by GPO overrides -ExecutionPolicy Bypass (then the restore script does not run)
    $r.GpoPolicy = [string](Get-ExecutionPolicy -Scope MachinePolicy)
    [pscustomobject]$r
}

$problems = @()
if (-not $chk.Completed) { $problems += 'C:\virtio-inject\completed.txt missing (WinPE did not run or ended with an error)' }
foreach ($s in 'viostor', 'vioscsi') {
    if ($chk."${s}Start" -ne '0') { $problems += "$s Start='$($chk."${s}Start")' instead of 0 (boot driver not ready)" }
    if ($chk."${s}Override")      { $problems += "$s StartOverride could not be removed (permissions?)" }
}
if (-not $chk.NetKvm) { $problems += 'netkvm missing in the driver store (no network after the migration)' }
if ($problems.Count -gt 0) {
    throw "VirtIO check failed, do NOT migrate:`n  - " + ($problems -join "`n  - ") +
          "`nLog on the server: C:\virtio-inject\inject.log. Repeat the WinPE run, then start this script again."
}
Write-Host "  VirtIO check ok: completed.txt, viostor/vioscsi Start=0 without StartOverride, netkvm present."
$removed = @('viostor', 'vioscsi' | Where-Object { $chk."${_}Removed" })
if ($removed.Count -gt 0) {
    Write-Host "  StartOverride removed for: $($removed -join ', ')." -ForegroundColor Yellow
}
if ($chk.GpoPolicy -in 'AllSigned', 'Restricted') {
    Write-Host "  WARNING: execution policy set by GPO = $($chk.GpoPolicy). The restore script will probably not start" -ForegroundColor Yellow
    Write-Host "  after the migration -> set the IP manually on the console of the target hypervisor (values: copy on the jump host)." -ForegroundColor Yellow
}
Write-Host ""

# ----------------------------------------------------------------------------
# 1. Read the configuration on the server (return only text/numbers,
#    so nothing gets lost in the WinRM transport)
# ----------------------------------------------------------------------------
Write-Host "Reading network configuration from $ComputerName ..."

$cfg = Invoke-Command @remote -ScriptBlock {
    $ErrorActionPreference = 'Stop'

    # Same count as in the restore script: all physical adapters, not only active ones
    $nics = @(Get-NetAdapter -Physical)
    if ($nics.Count -ne 1) {
        throw "Expected exactly 1 network adapter, found: $($nics.Count) ($(($nics | ForEach-Object Name) -join ', ')). Please save manually."
    }
    $nic = $nics[0]
    if ($nic.Status -ne 'Up') {
        throw "Network adapter '$($nic.Name)' is not up (status $($nic.Status))."
    }
    $idx = $nic.ifIndex

    $dhcp = [string](Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4).Dhcp
    $dnsClient = Get-DnsClient -InterfaceIndex $idx

    [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        Alias       = $nic.Name
        Description = $nic.InterfaceDescription
        Mac         = $nic.MacAddress
        Guid        = $nic.InterfaceGuid
        Dhcp        = $dhcp
        IPs         = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 |
                        Where-Object PrefixOrigin -eq 'Manual' |
                        ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        Gateway     = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Where-Object NextHop -ne '0.0.0.0' |
                        ForEach-Object NextHop | Sort-Object -Unique)
        Dns         = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses)
        Suffix      = [string]$dnsClient.ConnectionSpecificSuffix
        Register    = [bool]$dnsClient.RegisterThisConnectionsAddress
    }
}

if ($cfg.Dhcp -ne 'Disabled') {
    Write-Host "$ComputerName gets its IP via DHCP: nothing to save. VirtIO check ok, migration possible." -ForegroundColor Yellow
    Write-Host "If a DHCP reservation exists: update it to the new MAC of the VirtIO adapter after the migration." -ForegroundColor Yellow
    # Remove task/script of a previous run (static IP back then), otherwise it would set the old IP after the migration
    Invoke-Command @remote -ScriptBlock {
        Unregister-ScheduledTask -TaskName 'VirtIO-Restore-NetConfig' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item 'C:\virtio-inject\Restore-NetConfig.ps1' -Force -ErrorAction SilentlyContinue
    }
    return
}
if (-not $cfg.Guid) {
    throw "No InterfaceGuid read for '$($cfg.Alias)'. Aborting."
}
if ($cfg.IPs.Count -eq 0) {
    throw "$ComputerName has no static IPv4 address on '$($cfg.Alias)'. Please check manually."
}

Write-Host ""
Write-Host "  Adapter  : $($cfg.Alias) ($($cfg.Description)), MAC $($cfg.Mac)"
Write-Host "  IP       : $($cfg.IPs -join ', ')"
Write-Host "  Gateway  : $($cfg.Gateway -join ', ')"
Write-Host "  DNS      : $($cfg.Dns -join ', ')"
Write-Host "  Suffix   : $($cfg.Suffix)"
Write-Host "  DNS reg. : $($cfg.Register)"
Write-Host ""

# ----------------------------------------------------------------------------
# 2. Build the restore script: values at the top, fixed logic below
# ----------------------------------------------------------------------------
function ConvertTo-Literal([string]$Text) { "'" + ($Text -replace "'", "''") + "'" }
function ConvertTo-ArrayLiteral($Items) { '@(' + ((@($Items) | Where-Object { $_ } | ForEach-Object { ConvertTo-Literal $_ }) -join ', ') + ')' }

$header = @"
#Requires -Version 5.1
#Requires -RunAsAdministrator
# Created by Export-NetConfig.ps1 at $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME
# Sets the IPv4 configuration of $($cfg.Computer) on the new network adapter after the migration.
# Runs automatically at startup (scheduled task VirtIO-Restore-NetConfig, switch -AtStartup).
# Manual run (as administrator):
#   powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1
# After success the script deletes the task and itself; the log stays.
param([switch]`$AtStartup)

# Saved values (adapter '$($cfg.Alias)', $($cfg.Description), MAC $($cfg.Mac))
`$Computer       = $(ConvertTo-Literal $cfg.Computer)
`$OldGuid        = $(ConvertTo-Literal $cfg.Guid)
`$OldDescription = $(ConvertTo-Literal $cfg.Description)
`$IPs            = $(ConvertTo-ArrayLiteral $cfg.IPs)
`$Gateway        = $(ConvertTo-ArrayLiteral $cfg.Gateway)
`$Dns            = $(ConvertTo-ArrayLiteral $cfg.Dns)
`$Suffix         = $(ConvertTo-Literal $cfg.Suffix)
`$Register       = `$$($cfg.Register.ToString().ToLower())

"@

$body = @'
$ErrorActionPreference = 'Stop'
$TaskName = 'VirtIO-Restore-NetConfig'
Start-Transcript -Path 'C:\virtio-inject\Restore-NetConfig.log' -Append | Out-Null
try {
    # Safety: this script belongs to exactly this server
    if ($env:COMPUTERNAME -ne $Computer) {
        throw "This script belongs to $Computer, not to $env:COMPUTERNAME."
    }

    # If the script still runs on VMware, the old adapter is still there -> do not touch the network.
    # When booting on VMware, Windows sets StartOverride for viostor/vioscsi (no hardware) ->
    # remove it again, otherwise blue screen 0x7B on the first start on KVM.
    $stillVMware = "The old network adapter ($OldDescription) is still present (server is still running on VMware)."
    function Skip-OnVMware {
        foreach ($s in 'viostor', 'vioscsi') {
            Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$s\StartOverride" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "$stillVMware StartOverride (if present) removed, network not changed, next attempt at the next start."
    }
    if (Get-NetAdapter | Where-Object InterfaceGuid -eq $OldGuid) {
        if ($AtStartup) { Skip-OnVMware; return }
        throw "$stillVMware Run the script only after the migration."
    }

    # At startup Windows may still be setting up the new VirtIO adapter.
    # Check every 5 seconds, continue as soon as adapter + IPv4 interface exist (at most 5 minutes).
    $nics = @(Get-NetAdapter -Physical)
    if ($AtStartup) {
        $until = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $until) {
            $nics = @(Get-NetAdapter -Physical)
            if ($nics.Count -eq 1 -and
                (Get-NetIPInterface -InterfaceIndex $nics[0].ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Seconds 5
        }
    }
    if ($nics.Count -ne 1) {
        throw "Expected exactly 1 network adapter, found: $($nics.Count) ($(($nics | ForEach-Object Name) -join ', ')). Please set manually."
    }
    $nic = $nics[0]
    # Same adapter as before the migration (e.g. old adapter detected late at startup) -> do nothing
    if ($nic.InterfaceGuid -eq $OldGuid) {
        if ($AtStartup) { Skip-OnVMware; return }
        throw "$stillVMware Run the script only after the migration."
    }
    $idx = $nic.ifIndex
    Write-Host "New adapter: $($nic.Name) ($($nic.InterfaceDescription))"

    # Old, now hidden adapter: remove its IP entries,
    # otherwise Windows later reports "IP address is already assigned to another adapter"
    $oldKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$OldGuid"
    if (Test-Path $oldKey) {
        Set-ItemProperty -Path $oldKey -Name EnableDHCP -Value 1
        foreach ($name in 'IPAddress', 'SubnetMask', 'DefaultGateway', 'NameServer') {
            Remove-ItemProperty -Path $oldKey -Name $name -ErrorAction SilentlyContinue
        }
        Write-Host "IP entries of the old adapter removed."
    }

    # New adapter: DHCP off, remove existing IPv4 addresses/gateway (e.g. 169.254.x.x)
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    # Set the saved values
    foreach ($ip in $IPs) {
        $addr, $len = $ip -split '/'
        New-NetIPAddress -InterfaceIndex $idx -IPAddress $addr -PrefixLength $len | Out-Null
    }
    foreach ($gw in $Gateway) {
        New-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -NextHop $gw | Out-Null
    }
    if ($Dns.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $Dns
    }
    $dnsClient = @{ InterfaceIndex = $idx; RegisterThisConnectionsAddress = $Register }
    if ($Suffix) { $dnsClient.ConnectionSpecificSuffix = $Suffix }
    Set-DnsClient @dnsClient

    # Verify
    Get-NetIPConfiguration -InterfaceIndex $idx | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer
    if ($Gateway.Count -gt 0) {
        Start-Sleep -Seconds 3
        $pingOk = Test-Connection -ComputerName $Gateway[0] -Count 2 -Quiet
        Write-Host "Ping gateway $($Gateway[0]): $pingOk"
        if (-not $pingOk) { Write-Host "IP is set anyway -> check VLAN/network of the VM on the target hypervisor." }
    }

    # Clean up: remove this script and the task (the values are kept as a copy on the jump host).
    # Unregister the task last, in case that ends the running instance (not documented).
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up: $PSCommandPath and scheduled task $TaskName removed."
    Write-Host "Done."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    # Also write the reason to the log (otherwise the transcript ends before the error message)
    Write-Host "ERROR: $_" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
'@

# Consistent CRLF, so that Notepad on older servers also shows the lines correctly
$restoreScript = ($header + "`n" + $body) -replace "`r?`n", "`r`n"

# ----------------------------------------------------------------------------
# 3. Place it: on the server and as a copy on the jump host
# ----------------------------------------------------------------------------
Invoke-Command @remote -ArgumentList $restoreScript -ScriptBlock {
    param($Text)
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path 'C:\virtio-inject' -Force | Out-Null
    Set-Content -Path 'C:\virtio-inject\Restore-NetConfig.ps1' -Value $Text -Encoding UTF8

    # Run automatically at the next start (on KVM): as SYSTEM, without logon
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1 -AtStartup'
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'VirtIO-Restore-NetConfig' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}
Write-Host "Placed on the server: C:\virtio-inject\Restore-NetConfig.ps1"
Write-Host "Scheduled task VirtIO-Restore-NetConfig created: sets the IP automatically on the first start on KVM."

if (-not $LocalCopyPath) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location -PSProvider FileSystem).ProviderPath }
    $LocalCopyPath = Join-Path $base 'NetConfig'
}
$LocalCopyPath = (New-Item -ItemType Directory -Path $LocalCopyPath -Force).FullName
$localFile = Join-Path $LocalCopyPath "$($cfg.Computer)_Restore-NetConfig.ps1"
Set-Content -Path $localFile -Value $restoreScript -Encoding UTF8
Write-Host "Copy on the jump host:   $localFile"
