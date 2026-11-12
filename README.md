# vmware-to-kvm-virtio

These scripts move Windows Server VMs from **VMware** to a **KVM-based hypervisor** (e.g. HPE VM Essentials, Proxmox VE, Nutanix AHV, OpenStack) so that the VM **boots right away** on the target, without the `0x7B INACCESSIBLE_BOOT_DEVICE` blue screen.

**Core:** a custom **WinPE ISO** injects the VirtIO drivers (disk + network) **offline** into the Windows installation of the VM. This happens while the VM is still **on VMware**.

**Optional add-ons:**
- **`Prepare-KvmMigration.ps1`**, run before the migration: it checks the injection and fixes `StartOverride`. It restores the static IP automatically on the first boot on KVM, and it places the files for the cleanup.
- **`Cleanup-AfterMigration.ps1`**, run after the migration: it installs the remaining VirtIO drivers and the QEMU Guest Agent, removes VMware Tools and leftovers, and brings disks online.

**Supported:** Windows Server 2016, 2019, 2022, 2025 (x64), BIOS or UEFI.
**Not supported:** Server 2012 R2. Its VirtIO drivers are only test-signed, so Windows will not load them as boot drivers.

---

## Contents

```
vmware-to-kvm-virtio\
├─ WinPEFactory\                       CORE -> copy to C:\WinPEFactory
│  ├─ Build-WinPE.ps1                  builds the ISO
│  ├─ startnet.cmd                     WinPE autostart
│  └─ FilesToCopy\
│     ├─ driver_injection.ps1          injects the drivers
│     └─ VirtIO\                       (empty, drivers go here in step A3)
└─ AddOns\                             OPTIONAL
   ├─ Prepare-KvmMigration.ps1        runs on the admin PC / jump host
   └─ PostMigrationFiles\
      └─ Cleanup-AfterMigration.ps1    runs on the server (+ 2 MSI files, see "Add-on: Cleanup")
```

The VirtIO drivers are **not** included. Download them from the official source (step A3).

Windows blocks scripts downloaded from the internet. Unblock them once after downloading:
```powershell
Get-ChildItem <download folder> -Recurse | Unblock-File
```

---

## Part A: Build the ISO (once)

On a Windows admin PC, in **Windows PowerShell 5.1 as Administrator**.

**A1. Install the Windows ADK:** first the ADK itself (the feature "Deployment Tools" is enough), then the **separate** "WinPE add-on". Pick the ADK version for Windows Server 2025 (10.1.26100.x).
Download: https://learn.microsoft.com/windows-hardware/get-started/adk-install
If you install it to a non-default path, adjust `$ADKPath` in `Build-WinPE.ps1`.

**A2. Copy the `WinPEFactory` folder to `C:\WinPEFactory`.** Another path works too, because the script uses its own folder as the source. In that case adjust the paths in A3 and A4. The ISO is written to `C:\WinPE_Builds`.

**A3. Add the VirtIO drivers.** Download the virtio-win ISO (tested with **0.1.302**):
- Stable: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
- All versions: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/

Only `viostor`, `vioscsi` and `NetKVM` for 2016–2025 are copied, without debug files (`*.pdb`). This keeps the ISO small, because WinPE loads it completely into RAM.

```powershell
$iso = "$env:USERPROFILE\Downloads\virtio-win.iso"      # adjust path
$img = Mount-DiskImage -ImagePath $iso -PassThru
$src = "$((Get-Volume -DiskImage $img).DriveLetter):"
$dst = "C:\WinPEFactory\FilesToCopy\VirtIO"
foreach ($drv in "viostor", "vioscsi", "NetKVM") {
    foreach ($os in "2k16", "2k19", "2k22", "2k25") {
        robocopy "$src\$drv\$os\amd64" "$dst\$drv\$os\amd64" /E /XF *.pdb /NFL /NDL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Host "ERROR at $drv\$os" -ForegroundColor Red }
    }
}
Dismount-DiskImage -ImagePath $iso | Out-Null
Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum |
    ForEach-Object { "{0} files, {1:N1} MB" -f $_.Count, ($_.Sum / 1MB) }
Test-Path "$dst\viostor\2k25\amd64\viostor.inf"     # must be True
```
With 0.1.302 the result was 48 files and about 6 MB.

**A4. Build the ISO:** `C:\WinPEFactory\Build-WinPE.ps1`
Result: `C:\WinPE_Builds\Virtio-Drivers-PS.iso` (about 550 MB). Put it on a datastore your VMs can access.

---

## Part B: Per VM

Take a snapshot first, and test with a non-critical VM before you use it on important ones.

| # | Where | What |
|---|---|---|
| 1 | VMware | Shut down the VM and attach the ISO. Under *Edit Settings → VM Options → Boot Options*, enable "force entry into the EFI setup screen" (or BIOS setup) for the next boot. Start the VM, select the CD in the boot menu and **press a key at "Press any key to boot from CD"**. Do **not** change the boot order permanently. |
| 2 | VMware (console) | WinPE injects the drivers and **reboots**. **Do not press a key** this time, so Windows starts normally. If WinPE stops with a red **FAILED** message, read it first (see logs below), then reset the VM without pressing a key. Windows then starts unchanged. Disconnect the ISO afterwards. |
| 3 | Server | **Required:** check the drivers and remove `StartOverride` (see "Why it works this way"). Use **either** the add-on `Prepare-KvmMigration.ps1` **or** the commands below. |
| 4 | Migration tool | Migrate the VM to KVM (e.g. with Zerto, or OVF export/import). With the add-on, do **not** let the tool change the IP (no re-IP). |
| 5 | KVM | Check that the VM boots. Set the IP on the new VirtIO adapter manually, or let the add-on do it automatically. If needed, fix the VLAN of the VM on the target hypervisor. Without the add-on, additional disks may be offline and read-only (SAN policy). Bring them online (`Set-Disk <n> -IsOffline $false`, `-IsReadOnly $false`), but **not** shared cluster disks. |
| 6 | KVM | Finalize the migration (e.g. commit in Zerto). Then, optionally, run `Cleanup-AfterMigration.ps1`. |

Step 3 without the add-on: run this on the server as administrator, after the **last** reboot on VMware. Every reboot on VMware sets `StartOverride` again, so run it again after each reboot.
```powershell
Test-Path C:\virtio-inject\completed.txt          # must be True, otherwise repeat steps 1-2
'viostor', 'vioscsi' | ForEach-Object {
    Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$_\StartOverride" -Recurse -ErrorAction SilentlyContinue
    Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$_\StartOverride" }   # must be False, False
```

---

## Add-on: Prepare-KvmMigration.ps1

Run it on the admin PC / jump host after step 2 and before the migration: `.\Prepare-KvmMigration.ps1 -ComputerName <SERVER>`.

- **VirtIO check:** checks `completed.txt`, `Start=0` for viostor/vioscsi and netkvm in the driver store, and removes `StartOverride`. **If it says "VirtIO check failed": do NOT migrate**, repeat steps 1–2. Other problems only cause warnings. Read them before you migrate.
- **IP restore:** if there is exactly one adapter with a static IPv4, the script saves the IP and registers the scheduled task `VirtIO-Restore-NetConfig`. On the first boot on KVM, the task sets the IP, usually within seconds and before logon, and then deletes itself. On every boot on VMware, the task removes `StartOverride` again, so reboots before the migration are fine. **Without a working task** (DHCP, special case, GPO warning, task not created), run Prepare again after the last reboot on VMware. A copy of the values is kept in `NetConfig\` next to the script.
  For special cases (several adapters, adapter not up, no static IP, `SkipAsSource`), the script only shows the configuration and saves it as a text file on request. Set the IP manually after the migration. With DHCP there is nothing to save. Update a DHCP reservation to the new MAC address.
- **Cleanup files:** copies the script and the 2 MSI files from `PostMigrationFiles\` to `C:\virtio-inject` on the server. Put the MSI files there before you run Prepare (see "Add-on: Cleanup"), otherwise there is only a warning.
- **SAN policy:** sets it to `OnlineAll`, so that additional disks are online after the migration. It does **not** do this on cluster nodes or if a disk is already offline. The cleanup restores the old value. Without the cleanup, or if the migration is cancelled, reset it with the 2 commands in the script header.

Requirements: WinRM from the admin PC to the server works (`Test-WSMan <SERVER>`), and you have admin rights on the server. To use another account, add `-Credential (Get-Credential)`. If a GPO enforces the execution policy `AllSigned`/`Restricted`, the script warns that the restore and cleanup will not start.


## Add-on: Cleanup-AfterMigration.ps1

It needs 2 files from the **same** virtio-win ISO: `virtio-win-gt-x64.msi` (ISO root) and `qemu-ga-x86_64.msi` (folder `guest-agent`). Put them next to the script in `PostMigrationFiles\`, and Prepare copies everything to `C:\virtio-inject`. Without Prepare, copy the script and the 2 MSI files to `C:\virtio-inject` on the server manually.

Run it on the server, on the console of the target hypervisor, as administrator. Run it **only after the migration is final** (step 6), because the VM no longer boots cleanly on VMware afterwards:
```powershell
powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Cleanup-AfterMigration.ps1
```
It installs all VirtIO drivers and the QEMU Guest Agent, disables the AC'97 sound card and uninstalls VMware Tools. It also removes VMware leftovers and phantom devices (phantom devices only on Server 2022+), and brings disks online that are offline because of the SAN policy (not on cluster nodes). There is no automatic reboot. It can be run again, and completed steps are skipped. If VMware Tools need a reboot, reboot and run it again to remove the leftovers.

---

## Logs and troubleshooting

All files are on the VM in `C:\virtio-inject\`:

| File | Meaning |
|---|---|
| `inject.log` / `dism.log` | WinPE run / driver installation |
| `completed.txt` / `failed.txt` | WinPE run succeeded / failed |
| `Restore-NetConfig.log` | Add-on: applying the IP on KVM |
| `Cleanup-AfterMigration.log` | Add-on: cleanup |

Exception: if WinPE does not find Windows, the log exists only inside WinPE (`X:\virtio-ram.log`) and is lost on reboot. Read the console before you reset the VM.

| Symptom | Cause / fix |
|---|---|
| WinPE: "Windows not found" | WinPE cannot see the disk, or the volume is BitLocker-encrypted. Check the disk controller: LSI Logic SAS works, "VMware Paravirtual" (PVSCSI) is untested. |
| WinPE: "Unsupported build" | The VM is not Server 2016–2025. |
| ISO does not boot (Secure Boot) | Disable Secure Boot temporarily. VMs with the KB5025885 mitigations enabled need the 2023-signed boot files, and `Build-WinPE.ps1` does not support this out of the box. |
| Blue screen 0x7B on KVM | Step 3 was skipped, or the VM rebooted on VMware afterwards without the add-on task. Move the VM back to VMware and repeat steps 1–3. |
| chkdsk or boot errors on KVM after an earlier rollback | Zerto: after a rollback or a snapshot revert of the source VM, run *Force Sync* and wait for "Meeting SLA" before the next move. |
| IP is set, but gateway ping fails | Wrong VLAN/network of the VM on the target hypervisor |

---

## Why it works this way

- **Why WinPE on VMware?** WinPE itself has no VirtIO drivers. On KVM it would not see the disk at all, on VMware it does.
- **Why StartOverride?** When Windows boots on VMware after the injection, it finds no VirtIO hardware and disables the boot drivers with the registry key `StartOverride`. If the key is still there at the first boot on KVM, the VM gets a blue screen 0x7B.
- **Why "Press any key"?** After the WinPE run, the reboot falls through to Windows without a key press instead of booting into WinPE again.

---

## Tested with

Windows Server 2025, VMware vSphere 8 (LSI Logic SAS controller), virtio-win 0.1.302, HPE VM Essentials as target, Zerto as migration tool. Other combinations should work but are untested.

## License

MIT, see [LICENSE](LICENSE). No warranty. Use at your own risk.
