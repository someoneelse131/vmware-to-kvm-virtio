#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
==========================================================
 Cleanup-AfterMigration.ps1 (optional add-on)
==========================================================
Cleans up a Windows server after the move from VMware to KVM.

When:  after the migration is final (e.g. commit in the migration tool).
       Afterwards the VM no longer boots cleanly on VMware.
Where: on the server itself (console of the target hypervisor, as administrator).

Usage:
    powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Cleanup-AfterMigration.ps1
    Add -Force to skip the question "Continue? (Y/N)".

Needs these files in C:\virtio-inject (Prepare-KvmMigration.ps1 puts them there, or copy them by hand):
    Cleanup-AfterMigration.ps1, virtio-win-gt-x64.msi, qemu-ga-x86_64.msi
    Use the MSI files from the same virtio-win version as the WinPE ISO.

What it does, step by step:
- 1. Stops if the VM is still running on VMware.
- 2. Brings additional disks online that Windows set offline after the migration.
     Not on cluster nodes, and not if disks were already offline on VMware.
     Sets the SAN policy back to the value before Prepare-KvmMigration.ps1.
- 3. Installs the other VirtIO drivers (Balloon, Serial, RNG, ...) and the QEMU Guest Agent.
- 4. Disables the AC'97 sound card (Windows Server has no driver for it).
- 5. Uninstalls VMware Tools.
- 6. Removes VMware leftovers (folder, driver packages).
- 7. Removes phantom devices of the old VMware hardware (Server 2022 and later).

Notes:
- Run it in a maintenance window: step 3 can interrupt the network for a moment.
  On cluster nodes, pause the node first.
- No automatic reboot.
- You can run it again: finished steps are skipped.
  If VMware Tools need a reboot: reboot, then run it again to remove the leftovers.
- Log: C:\virtio-inject\Cleanup-AfterMigration.log
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'

# ==========================================================
# CONFIG
# ==========================================================

$dir      = 'C:\virtio-inject'
$warnings = New-Object System.Collections.Generic.List[string]
$changed  = $false   # did we change something? Then we recommend a reboot at the end.

# ==========================================================
# FUNCTIONS
# ==========================================================

# Show a warning and remember it for the summary at the end
function Warn([string]$Text) {
    Write-Host "WARNING: $Text" -ForegroundColor Yellow
    $warnings.Add($Text)
}

function Step([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Get-Installed([string]$Name) {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
}

function Invoke-Msi([string]$Arguments) {
    (Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru).ExitCode
}

# Run pnputil, hide its output, return the exit code.
# (Error output of pnputil must not stop the script.)
function Invoke-PnpUtil([string[]]$Arguments) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & pnputil.exe @Arguments 2>&1
        $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $eap
    }
}

# ==========================================================
# START
# ==========================================================

New-Item -ItemType Directory -Path $dir -Force | Out-Null
Start-Transcript -Path "$dir\Cleanup-AfterMigration.log" -Append | Out-Null

try {
    # ==========================================================
    # 1. SAFETY
    # ==========================================================

    # 64-bit PowerShell only (the 32-bit one sees a different registry)
    if (-not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit PowerShell (not SysWOW64).'
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "Server: $env:COMPUTERNAME   Manufacturer: $($cs.Manufacturer)   Model: $($cs.Model)"
    if ($cs.Manufacturer -like 'VMware*') {
        throw 'The VM is still running on VMware. Run this only after the migration is final.'
    }

    if (-not $Force) {
        Write-Host 'Installs the VirtIO drivers + QEMU Guest Agent and removes VMware Tools.'
        Write-Host 'Run only after the migration is final: afterwards the VM no longer boots cleanly on VMware.'
        Write-Host 'The network can be interrupted briefly (maintenance window).'
        if ((Read-Host 'Continue? (Y/N)') -notmatch '^[Yy]') {
            Write-Host 'Cancelled, nothing changed.'
            return
        }
    }

    # ==========================================================
    # 2. DISKS
    # ==========================================================
    # After the migration Windows sees the disks as new disks.
    # Because of the SAN policy it can set additional disks offline and read-only.

    Step 'Disks'

    # Set the SAN policy back (Prepare-KvmMigration.ps1 changed it for the migration).
    # This only affects disks added in the future. We do it first, so an error below cannot skip it.
    $sanFile = Join-Path $dir 'SanPolicy-Original.txt'
    if (Test-Path $sanFile) {
        $oldPolicy = ([string](Get-Content $sanFile -TotalCount 1)).Trim()
        try {
            Set-StorageSetting -NewDiskPolicy $oldPolicy
            Remove-Item $sanFile -Force
            Write-Host "SAN policy back to $oldPolicy."
        }
        catch {
            Warn "SAN policy not set back to '$oldPolicy': $($_.Exception.Message)"
        }
    }

    # When do we NOT bring disks online automatically?
    # - on a cluster node (the cluster manages shared disks)
    # - if disks were already offline on VMware (maybe shared; Prepare wrote them to a file)
    # Bringing a shared disk online can destroy data.
    $onlined = @()
    $hold = $null
    if (Get-Service -Name ClusSvc -ErrorAction SilentlyContinue) {
        $hold = 'cluster node'
    }
    elseif (Test-Path (Join-Path $dir 'Disks-Offline-VMware.txt')) {
        $hold = "offline on VMware already: disk(s) $((Get-Content (Join-Path $dir 'Disks-Offline-VMware.txt') -TotalCount 1))"
    }

    foreach ($d in @(Get-Disk | Where-Object IsOffline)) {
        if ($hold) {
            Warn "Disk $($d.Number) is offline (reason: $($d.OfflineReason)) - not touched ($hold). Check whether it is shared."
        }
        elseif (@('1', 'Policy') -contains [string]$d.OfflineReason) {
            # Offline because of the SAN policy -> make it writable and bring it online
            if ($d.IsReadOnly) {
                Set-Disk -Number $d.Number -IsReadOnly $false
            }
            Set-Disk -Number $d.Number -IsOffline $false
            if ((Get-Disk -Number $d.Number).IsReadOnly) {
                Set-Disk -Number $d.Number -IsReadOnly $false
            }
            Write-Host "Disk $($d.Number) brought online."
            $onlined += $d.Number
            $changed = $true
        }
        else {
            Warn "Disk $($d.Number) is offline (reason: $($d.OfflineReason)) - not touched, check manually."
        }
    }

    if ($onlined.Count -gt 0) {
        Warn "Disk(s) $($onlined -join ', ') brought online - reboot REQUIRED before SQL/AD services are used."
    }

    Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter |
        Format-Table DriveLetter, FileSystemLabel, @{ n = 'GB'; e = { [math]::Round($_.Size / 1GB, 1) } } -AutoSize | Out-Host

    # ==========================================================
    # 3. VIRTIO DRIVERS + QEMU GUEST AGENT
    # ==========================================================
    # WinPE only injected the disk and network drivers.
    # The MSI files install all VirtIO drivers and the QEMU Guest Agent.

    Step 'VirtIO drivers and QEMU Guest Agent'

    $packages = @(
        @{ File = 'virtio-win-gt-x64.msi'; Name = 'Virtio-win-driver-installer' },
        @{ File = 'qemu-ga-x86_64.msi';    Name = 'QEMU guest agent' }
    )

    foreach ($pkg in $packages) {
        $path = Join-Path $dir $pkg.File

        if (Get-Installed $pkg.Name) {
            Write-Host "$($pkg.Name): already installed."
            continue
        }

        if (-not (Test-Path $path)) {
            Warn "$path missing - $($pkg.Name) not installed."
            continue
        }

        # Install silently (3010 = ok, reboot needed)
        Write-Host "Installing $($pkg.File) ..."
        $changed = $true
        $exit = Invoke-Msi "/i `"$path`" /qn /norestart /l*v `"$dir\$($pkg.File).log`""
        if (@(0, 3010) -contains $exit) {
            Write-Host "  ok (exit code $exit)"
        } else {
            Warn "$($pkg.File): exit code $exit, log $dir\$($pkg.File).log"
        }
    }

    if (Get-Service QEMU-GA -ErrorAction SilentlyContinue) {
        Start-Service QEMU-GA -ErrorAction SilentlyContinue
        $ga = Get-Service QEMU-GA
        if ($ga.Status -eq 'Running') {
            Write-Host 'QEMU Guest Agent is running.'
        } else {
            Warn "QEMU Guest Agent is not running (status $($ga.Status)) - check again after the reboot."
        }
    }

    # ==========================================================
    # 4. SOUND CARD
    # ==========================================================
    # Some KVM hypervisors add an AC'97 sound card (PCI 8086:2415). Windows Server has no driver,
    # so it shows as an error in the Device Manager. Disable it (cosmetic only).

    Step 'Sound card'

    $audio = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_8086&DEV_2415*' })
    if ($audio.Count -eq 0) {
        Write-Host 'No AC97 sound card present.'
    }

    foreach ($a in $audio) {
        # Error code 22 = already disabled (e.g. by an earlier run)
        if ([int]$a.ConfigManagerErrorCode -eq 22) {
            Write-Host "Already disabled: $($a.FriendlyName)"
            continue
        }
        try {
            Disable-PnpDevice -InstanceId $a.InstanceId -Confirm:$false
            Write-Host "Disabled: $($a.FriendlyName)"
            $changed = $true
        }
        catch {
            Warn "Sound card not disabled: $($_.Exception.Message)"
        }
    }

    # ==========================================================
    # 5. UNINSTALL VMWARE TOOLS
    # ==========================================================
    # Normally VMware Tools refuse to uninstall on non-VMware hardware
    # (the check "VM_CheckRequirements" in the MSI stops it).
    # Workaround from the community (not from VMware):
    # remove this check from the cached MSI, then uninstall normally.

    Step 'Uninstall VMware Tools'

    $toolsExit = $null
    $tools = Get-Installed 'VMware Tools'

    if (-not $tools) {
        Write-Host 'VMware Tools not installed (anymore).'
    }
    else {
        $code = $tools.PSChildName
        Write-Host "Found: VMware Tools $($tools.DisplayVersion) $code"

        # Find the cached MSI that Windows uses for the uninstall
        $cache = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' |
            ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath 'InstallProperties') -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -eq 'VMware Tools' } | Select-Object -First 1
        $msi = [string]$cache.LocalPackage

        if (-not $msi -or -not (Test-Path $msi)) {
            Warn 'Cached VMware Tools MSI not found - not uninstalled, check manually.'
        }
        else {
            $patched = $false
            try {
                # Backup first
                $backup = "$dir\VMwareTools-original.msi"
                if (-not (Test-Path $backup)) {
                    Copy-Item $msi $backup
                }
                Write-Host "MSI: $msi (backup: $backup)"
                Set-ItemProperty $msi -Name IsReadOnly -Value $false

                # Open the MSI database and delete the check
                $installer = New-Object -ComObject WindowsInstaller.Installer
                $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($msi, [int]1))
                foreach ($table in 'CustomAction', 'InstallExecuteSequence') {
                    $sql = "DELETE FROM $table WHERE Action='VM_CheckRequirements' OR Action='VM_LogStart'"
                    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
                    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
                }

                [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
                $patched = $true
            }
            catch {
                Warn "MSI could not be modified: $($_.Exception.Message) - not uninstalled."
            }

            # Uninstall. Success = VMware Tools are no longer listed as installed.
            if ($patched) {
                Write-Host 'Uninstalling (can take a few minutes) ...'
                $changed = $true
                $toolsExit = Invoke-Msi "/x $code /qn /norestart /l*v `"$dir\VMwareTools-uninstall.log`""
                if (Get-Installed 'VMware Tools') {
                    Warn "VMware Tools still installed (exit code $toolsExit), log $dir\VMwareTools-uninstall.log - leftovers NOT removed."
                }
                elseif ($toolsExit -eq 3010) {
                    Warn 'VMware Tools uninstalled, reboot required. Then run this script again (it removes the leftovers).'
                }
                else {
                    Write-Host "  ok (exit code $toolsExit)"
                }
            }
        }
    }

    # ==========================================================
    # 6. VMWARE LEFTOVERS
    # ==========================================================
    # Only if VMware Tools are gone and no reboot is pending.
    # If the uninstall failed, we delete nothing by hand.

    Step 'VMware leftovers'

    if (Get-Installed 'VMware Tools') {
        Write-Host 'Skipped, because VMware Tools are still installed.'
    }
    elseif ($toolsExit -eq 3010) {
        Write-Host 'Skipped until after the reboot.'
    }
    else {
        foreach ($name in 'VMTools', 'VGAuthService', 'VM3DService', 'vmvss') {
            if (Get-Service $name -ErrorAction SilentlyContinue) {
                Warn "Service $name still exists - check manually."
            }
        }

        $folder = Join-Path $env:ProgramFiles 'VMware\VMware Tools'
        if (Test-Path $folder) {
            Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $folder) {
                Warn "$folder not deleted completely (files in use) - run the script again after a reboot."
            } else {
                Write-Host "$folder deleted."
            }
            $changed = $true
        }

        $parent = Split-Path $folder
        if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) {
            Remove-Item $parent -Force
        }

        # Driver packages: only if it is safe.
        # Not if another VMware product is installed, and not if Windows still uses a
        # VMware filter driver (vm*). Removing it then could stop Windows from booting.
        $other = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like '*VMware*' } | ForEach-Object DisplayName)
        $filters = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class' -ErrorAction SilentlyContinue |
                     ForEach-Object { $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue; @($p.UpperFilters) + @($p.LowerFilters) } |
                     Where-Object { $_ -like 'vm*' })

        if ($other.Count -gt 0) {
            Warn "Other VMware product installed ($($other -join ', ')) - driver packages not touched."
        }
        elseif ($filters.Count -gt 0) {
            Warn "Class filter still points to $($filters -join ', ') - driver packages not touched, check manually."
        }
        else {
            $drivers = @(Get-WindowsDriver -Online | Where-Object { $_.ProviderName -like 'VMware*' })
            if ($drivers.Count -eq 0) {
                Write-Host 'No VMware driver packages left in the driver store.'
            }
            foreach ($drv in $drivers) {
                $rc = Invoke-PnpUtil @('/delete-driver', $drv.Driver, '/uninstall', '/force')
                if (@(0, 3010) -contains $rc) {
                    Write-Host "Driver package removed: $($drv.Driver) ($(Split-Path $drv.OriginalFileName -Leaf))"
                    $changed = $true
                } else {
                    Warn "Driver package $($drv.Driver) not removed (pnputil exit code $rc)."
                }
            }
        }
    }

    # ==========================================================
    # 7. PHANTOM DEVICES
    # ==========================================================
    # The old VMware hardware is still listed as hidden devices. Remove them (cosmetic only).
    # We find them by their IDs: PCI vendor 15AD (also as subsystem), USB 0E0F, ACPI VMW*,
    # SCSI VEN_VMWARE / NECVMWAR, plus the old CPUs of the ESXi hosts.

    Step 'Phantom devices'

    # "pnputil /remove-device" only exists from build 19041 on
    if ([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 19041) {
        Write-Host 'pnputil /remove-device exists only on Server 2022 and later - skipped (cosmetic only).'
    }
    else {
        $pattern = 'VEN_15AD|SUBSYS_[0-9A-F]{4}15AD|VID_0E0F|\\VMW0|VMWARE|NECVMWAR'
        $ghosts = @(Get-PnpDevice | Where-Object {
            -not $_.Present -and ($_.InstanceId -match $pattern -or $_.FriendlyName -like '*VMware*' -or $_.Class -eq 'Processor')
        })

        $removed = 0
        foreach ($g in $ghosts) {
            $rc = Invoke-PnpUtil @('/remove-device', $g.InstanceId)
            if (@(0, 3010) -contains $rc) {
                $removed++
            }
            elseif (Get-PnpDevice -InstanceId $g.InstanceId -ErrorAction SilentlyContinue) {
                Warn "Not removed: $($g.FriendlyName) [$($g.InstanceId)]"
            }
        }

        Write-Host "$removed of $($ghosts.Count) phantom devices removed."
        if ($removed -gt 0) {
            $changed = $true
        }
    }

    # ==========================================================
    # RESULT
    # ==========================================================

    Step 'Result'

    # Devices that still have a problem (except the disabled sound card)
    $problems = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -notlike 'PCI\VEN_8086&DEV_2415*' })
    if ($problems.Count -gt 0) {
        Write-Host 'Devices with a problem (check again after the reboot):'
        $problems | Format-Table Status, Class, FriendlyName, InstanceId -AutoSize | Out-Host
    }

    if ($warnings.Count -eq 0) {
        Write-Host 'Done without warnings.' -ForegroundColor Green
    } else {
        Write-Host "Done with $($warnings.Count) warning(s):" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }

    if ($changed -or $warnings.Count -gt 0) {
        Write-Host 'Please reboot the server. No automatic reboot.'
    } else {
        Write-Host 'Nothing changed - no reboot needed.'
    }
    Write-Host "Log: $dir\Cleanup-AfterMigration.log"
}
catch {
    Write-Host "ABORTED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    throw
}
finally {
    Stop-Transcript | Out-Null
}
