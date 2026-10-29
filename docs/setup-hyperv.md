# Setup — Hyper-V

The hypervisor is **not** part of the experimental apparatus. Test volumes are VHDX files created from inside the guest, and a control run on a physical-backed system volume confirmed VHDX backing is transparent to NTFS timestamp behaviour (see `results/*/findings.md` §5).

This guide therefore covers only guest creation. From step 4 onward it is identical to [setup-vmware.md](setup-vmware.md), and to bare metal.

Requires Windows Pro, Enterprise or Education — **Home has no Hyper-V**.

## 1. Create the VM

A **Generation 2** VM has native vTPM and Secure Boot, so Windows 11 installs with no workaround. This is the one place Hyper-V is less fiddly than Workstation, which requires encrypting the VM before a TPM can be attached.

```powershell
New-VM -Name 'NtfsTimestamps' -Generation 2 -MemoryStartupBytes 8GB `
       -NewVHDPath 'D:\VMs\NtfsTimestamps\system.vhdx' -NewVHDSizeBytes 256GB

Set-VMProcessor      -VMName 'NtfsTimestamps' -Count 4
Set-VMFirmware       -VMName 'NtfsTimestamps' -EnableSecureBoot On
Set-VMKeyProtector   -VMName 'NtfsTimestamps' -NewLocalKeyProtector
Enable-VMTPM         -VMName 'NtfsTimestamps'
Add-VMDvdDrive       -VMName 'NtfsTimestamps' -Path 'D:\ISO\<installer>.iso'
```

**256 GB for the system disk, not 100 GB.** At 100 GB the system volume would itself fall below the historical 128 GB threshold, quietly making your "normal" volume a small-volume case.

Dynamic expansion is the default, so the real footprint is far smaller.

## 2. Install Windows

Verify the ISO hash first (see [provenance.md](provenance.md)):

```powershell
(Get-FileHash .\<installer>.iso -Algorithm SHA256).Hash
```

**Install with internet access.** Windows 11 setup requires a Microsoft account to complete OOBE, so the guest cannot start out isolated. Attach it to the **Default Switch**, which provides NAT:

```powershell
Connect-VMNetworkAdapter -VMName 'NtfsTimestamps' -SwitchName 'Default Switch'

$dvd = Get-VMDvdDrive -VMName 'NtfsTimestamps'
Set-VMFirmware -VMName 'NtfsTimestamps' -FirstBootDevice $dvd
Start-VM -Name 'NtfsTimestamps'
```

Sign in with a throwaway Microsoft account and finish setup. Then, in the guest, create a **local administrator account** for the harness to connect as:

```powershell
New-LocalUser -Name '<harness-user>' -Password (Read-Host -AsSecureString) -PasswordNeverExpires
Add-LocalGroupMember -Group 'Administrators' -Member '<harness-user>'
```

Everything from here runs as that local account — PowerShell Direct authenticates against the guest's local accounts, and a disposable credential is the right thing to hand a lab VM.

> Signing in with a Microsoft account brings OneDrive with it. That is acceptable because the test volumes (`V:`, `W:`, `X:`) are outside anything OneDrive syncs, and `Set-AmbientConfig.ps1 -Mode CleanRoom` stops it before a run. Do not place case directories under the user profile.

## 3. Isolate the guest

Setup is finished, so move the guest off the Default Switch to one with no external connectivity:

```powershell
New-VMSwitch -Name 'Isolated' -SwitchType Private
Connect-VMNetworkAdapter -VMName 'NtfsTimestamps' -SwitchName 'Isolated'
```

A **private** switch isolates the guest from the host as well, which also blocks PowerShell Remoting. Use **internal** instead if you want to drive the guest from the host over the network:

```powershell
New-VMSwitch -Name 'HostOnly' -SwitchType Internal
```

Either way the guest cannot reach the internet, so Windows Update, Defender signature updates, and anything else that might touch files or replace system components mid-project are all blocked.

### PowerShell Direct — the Hyper-V advantage

Hyper-V can drive the guest **without any network at all**, which pairs well with a private switch:

```powershell
Invoke-Command -VMName 'NtfsTimestamps' -Credential (Get-Credential) -ScriptBlock { ... }
Copy-Item .\ -Destination C:\NtfsTest\repo -ToSession (New-PSSession -VMName 'NtfsTimestamps' -Credential $cred) -Recurse
```

No `Enable-PSRemoting`, no `TrustedHosts`, no listener. If you use an internal switch instead, set it up as in [setup-vmware.md](setup-vmware.md).

> **Credentials.** Use a throwaway local account. Never reuse a real credential, and never commit one to a repository.

Take a checkpoint named `BASELINE-<build>` once provisioning finishes.

## 4. Provision and run

Identical to [setup-vmware.md](setup-vmware.md) steps 4–5. In brief:

```powershell
# host, with internet
.\provision\Get-Tools.ps1

# guest, elevated
Set-ExecutionPolicy Bypass -Scope Process -Force
.\provision\New-TestVolumes.ps1 -Force
.\provision\Set-AmbientConfig.ps1 -Mode CleanRoom
.\harness\Invoke-FullRun.ps1 -SettleSeconds 20
```

The .NET 9 Runtime and the VC++ 2015–2022 redistributable must be staged from the host; neither is present on a clean install, and the guest has no internet. Missing VC++ makes `mft_dump` exit `0xC0000135` **silently**.

## Note on coexistence

Enabling Hyper-V puts VMware Workstation on the Windows Hypervisor Platform, which costs performance. If you rely on Workstation for other work, that is the tradeoff — and the reason this project does not require either hypervisor.

## Gotchas

**Explorer-driven tests need the console.** Remoting and PowerShell Direct are both non-interactive, so a manual pass runs at the guest console, and `Invoke-ExplorerTest.ps1` refuses to start one outside an interactive session. The automated pass runs over Remoting or PowerShell Direct but acts on the console session, so the harness user must be logged on there with the desktop unlocked. See [explorer-test-plan.md](explorer-test-plan.md).

**The search indexer restarts itself.** `WSearch` is `Auto` with `DelayedAutostart`; stopping it does not keep it stopped. Verify in the fingerprint comparison rather than assuming. See [methodology.md](methodology.md).

**VHDX attachment does not survive a reboot** — run `.\provision\Mount-TestVolumes.ps1`.
