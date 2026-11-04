# vmware-to-kvm-virtio

Use these scripts to move Windows Server VMs from **VMware** to a **KVM-based hypervisor** (e.g. HPE VM Essentials, Proxmox VE, Nutanix AHV, OpenStack) so that the VM **boots right away** on the target. There is no `0x7B INACCESSIBLE_BOOT_DEVICE` blue screen, and the **static IP is restored automatically**.

**How it works**

1. A custom **WinPE ISO** injects the VirtIO drivers (disk + network) **offline** into the Windows installation of the VM. This happens while the VM is still **on VMware**.
2. **`Export-NetConfig.ps1`** verifies the injection and saves the IPv4 configuration. It also registers a scheduled task (`VirtIO-Restore-NetConfig`) that applies the IP to the new VirtIO network adapter **on the first boot on KVM**.

**Supported:** Windows Server 2016, 2019, 2022, 2025 (x64), BIOS or UEFI, VMs with **one** network adapter.
**Not supported:** Server 2012 R2. Its VirtIO drivers are only test-signed, so Windows will not load them as boot drivers.

---

## Contents

```
vmware-to-kvm-virtio\
├─ Export-NetConfig.ps1            -> run on your admin PC / jump host
└─ WinPEFactory\                   -> copy to C:\WinPEFactory
   ├─ Build-WinPE.ps1              builds the ISO
   ├─ startnet.cmd                 WinPE autostart
   └─ FilesToCopy\
      ├─ driver_injection.ps1      injects the drivers
      └─ VirtIO\                   (empty, drivers go here in step A3)
```

The VirtIO drivers are **not** included. Download them from the official source (step A3).

Windows blocks scripts downloaded from the internet. Unblock them once after downloading:
```powershell
Get-ChildItem <download folder> -Recurse | Unblock-File
```

---

## Part A: Build the ISO (once)

On a Windows admin PC, in **Windows PowerShell 5.1 as Administrator**.

**A1. Install the Windows ADK:** first the ADK itself (the feature "Deployment Tools" is enough), then the **separate** "WinPE add-on". Pick the ADK version that supports Windows Server 2025 (10.1.26100.x), not a newer one that is only for a newer Windows client release.
Download: https://learn.microsoft.com/windows-hardware/get-started/adk-install
If you install it to a non-default path, adjust `$ADKPath` in `Build-WinPE.ps1`.

**A2. Copy the `WinPEFactory` folder to `C:\WinPEFactory`.**
Another path works too, because the script uses its own folder as the source. In that case adjust the paths in A3 and A4. The finished ISO is written to `C:\WinPE_Builds`.

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

**A4. Build the ISO:**
```powershell
C:\WinPEFactory\Build-WinPE.ps1
```
Result: `C:\WinPE_Builds\Virtio-Drivers-PS.iso` (about 550 MB). Put it on a datastore your VMs can access.

---

## Part B: Per VM

Take a snapshot first, and try it with a non-critical VM before you use it on important ones.

| # | Where | What |
|---|---|---|
| 1 | **VMware** | Shut down the VM and attach the ISO. Under *Edit Settings → VM Options → Boot Options*, enable "force entry into the EFI setup screen" (or BIOS setup) for the next boot. Start the VM, select the CD in the boot menu and **press a key at "Press any key to boot from CD"**. Do **not** change the boot order permanently. |
| 2 | VMware (console) | WinPE injects the drivers and **reboots**. **Do not press a key** this time, so Windows starts normally. If WinPE stops with a red **FAILED** message, read it first (see logs below), then reset the VM without pressing a key. Windows starts unchanged. |
| 3 | Admin PC / jump host | Run `.\Export-NetConfig.ps1 -ComputerName <SERVER>` (see the requirements below). It checks the drivers, saves the IP and registers the task. **If it says "VirtIO check failed": do NOT migrate**, repeat steps 1–2 instead. |
| 4 | Migration tool | Disconnect the ISO. Migrate the VM to KVM (e.g. Zerto, OVF export/import). Do **not** let the tool change the IP (no re-IP). Reboots on VMware between steps 3 and 4 are fine, **but only if the task was created**. With DHCP or a GPO warning there is no working task, so run step 3 again after the last reboot on VMware. |
| 5 | KVM (automatic) | On the first boot the task applies the IP. This usually takes seconds and happens before logon. Then the task deletes itself. Check with ping/RDP. If needed, fix the VLAN of the VM on the target hypervisor. |
| 6 | Afterwards | Uninstall VMware Tools. Optionally install the QEMU Guest Agent (it is on the virtio-win ISO). Only then finalize the migration (e.g. commit in Zerto). |

**If the IP is not applied automatically** (console of the target hypervisor, as administrator):
```powershell
powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1
```
A copy of the saved values is also kept on the admin PC, in the `NetConfig\` folder next to the script.

---

## Requirements for Export-NetConfig.ps1

- WinRM from the admin PC to the server works (`Test-WSMan <SERVER>`), and you have admin rights on the server. To use another account, add `-Credential (Get-Credential)`.
- The server has **exactly one** network adapter, and it is up. Otherwise the script aborts, and you need to save the configuration manually.
- With **DHCP** there is nothing to save. The script only runs the driver check. Remember to update a DHCP reservation to the new MAC address.
- If a GPO enforces the execution policy `AllSigned`/`Restricted`, the script warns you. In that case you have to set the IP manually.

---

## Logs and troubleshooting

All files are on the VM in `C:\virtio-inject\`:

| File | Meaning |
|---|---|
| `inject.log` / `dism.log` | WinPE run / driver installation |
| `completed.txt` | WinPE run succeeded |
| `failed.txt` | WinPE run failed |
| `Restore-NetConfig.log` | Applying the IP on KVM |

Exception: if WinPE does not find Windows, the log exists only inside WinPE (`X:\virtio-ram.log`) and is lost on reboot. Read the console before you reset the VM.

| Symptom | Cause / fix |
|---|---|
| WinPE: "Windows not found" | WinPE cannot see the disk, or the volume is BitLocker-encrypted. Check the disk controller: LSI Logic SAS works, "VMware Paravirtual" (PVSCSI) is untested. |
| WinPE: "Unsupported build" | Not Server 2016–2025 |
| ISO does not boot (Secure Boot) | Disable Secure Boot temporarily. VMs with the KB5025885 mitigations enabled need the 2023-signed boot files; `Build-WinPE.ps1` does not support this out of the box. |
| Blue screen 0x7B on KVM | Step 3 was skipped or failed, or the VM rebooted on VMware afterwards without a working task. Move the VM back to VMware and repeat steps 1–3. |
| IP is set, but gateway ping fails | Wrong VLAN/network of the VM on the target hypervisor |

---

## Why it works this way

- **Why WinPE on VMware?** WinPE itself has no VirtIO drivers. On KVM it would not see the disk at all, on VMware it does.
- **Why Export-NetConfig *after* the WinPE run?** When Windows boots on VMware, it finds no VirtIO hardware and disables the boot drivers (registry key `StartOverride`). The script removes that key, otherwise the VM gets a blue screen 0x7B on KVM. The scheduled task does the same at every further boot on VMware.
- **Why "Press any key"?** After the WinPE run, the reboot then falls through to Windows without a key press instead of booting into WinPE again.

---

## Tested with

Windows Server 2025, VMware vSphere 8 (LSI Logic SAS controller), virtio-win 0.1.302, HPE VM Essentials as target, Zerto as migration tool. Other combinations should work but are untested.

## License

MIT, see [LICENSE](LICENSE). No warranty. Use at your own risk.
