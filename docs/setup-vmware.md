# Setup — VMware Workstation

The hypervisor is **not** part of the experimental apparatus. Test volumes are VHDX files created from inside the guest, which needs no Hyper-V role, and a control run on a physical-backed system volume confirmed VHDX backing is transparent to NTFS timestamp behavior (see `results/*/findings.md` §5).

So this guide only covers getting a guest running. Everything from step 4 onward is identical on any hypervisor, or on bare metal.

## Requirements

- VMware Workstation 17.5 or later
- Windows 11 installation media, hash-verified (see [provenance.md](provenance.md))
- 80+ GB host disk free space for the guest

## 1. Create the VM

| Setting | Value |
|---|---|
| Firmware | **UEFI with Secure Boot** |
| Trusted Platform Module | **Added** |
| Hardware version | 21 |
| Memory | 8 GB |
| Processors | 4 |
| System disk | 256 GB, thin-provisioned, single file |
| Network | **NAT** for installation, switched to **host-only** afterwards (see step 3) |

**The vTPM is the step that usually blocks a Windows 11 install.** Workstation requires the VM be encrypted before a TPM can be attached — choose *"encrypt only the files needed to support a TPM"*, not full-VM encryption.

**The system disk should be 256 GB, not 100 GB.** At 100 GB the system volume would itself sit below the historical 128 GB threshold, quietly making your "normal" volume a small-volume case. Measured results show the threshold has no effect on Win11 25H2, but there is no reason to build the ambiguity in.

## 2. Install Windows

Verify the ISO hash first:

```powershell
(Get-FileHash .\<installer>.iso -Algorithm SHA256).Hash
```

**Install with the adapter on NAT.** Windows 11 setup requires a Microsoft account to complete OOBE, which needs internet — so the guest cannot start out isolated. Sign in with a throwaway Microsoft account and finish setup.

Then create a **local administrator account** for the harness to connect as:

```powershell
New-LocalUser -Name '<harness-user>' -Password (Read-Host -AsSecureString) -PasswordNeverExpires
Add-LocalGroupMember -Group 'Administrators' -Member '<harness-user>'
```

Everything from here runs as that local account. A Microsoft account cannot be used for PowerShell Remoting to a workgroup machine, and the local account keeps the credential disposable.

> Signing in with a Microsoft account brings OneDrive with it. That is acceptable because the test volumes (`V:`, `W:`, `X:`) are outside anything OneDrive syncs, and `Set-AmbientConfig.ps1 -Mode CleanRoom` stops it before a run. Do not place case directories under the user profile.

## 3. Isolate the guest

**Switch the adapter to host-only now that setup is finished.** This blocks Windows Update, Defender signature updates, and every other background fetch — all of which can touch files or replace system components mid-project.

Belt-and-braces, if you want Windows Update off as well:

- `Computer Configuration → Administrative Templates → Windows Components → Windows Update → Configure Automatic Updates → Disabled`
- Set the `wuauserv` service to Disabled

Setting the service alone does not stick; Windows restarts it.

Enable PowerShell Remoting so the harness can drive the guest from the host:

```powershell
Enable-PSRemoting -Force
```

`Enable-PSRemoting` **refuses while any connection is on the Public profile**, and a host-only adapter frequently comes up that way. Check and correct it first:

```powershell
Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceAlias 'Ethernet0' -NetworkCategory Private
```

On the **host**, trust the guest's address. A workgroup guest has no Kerberos, so NTLM requires the client to trust the target explicitly:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<guest-ip>' -Force
```

> **Credentials.** Use a throwaway local account. The guest is an isolated lab VM on a host-only network — never reuse a real credential, and never commit one to a repository.

Take a snapshot named `BASELINE-<build>` once provisioning finishes.

## 4. Provision (hypervisor-independent from here)

On a host with internet, fetch and pin the parsers:

```powershell
.\provision\Get-Tools.ps1
```

Copy the repo and `tools/` to the guest. Over PowerShell Remoting:

```powershell
$s = New-PSSession -ComputerName <guest-ip> -Credential (Get-Credential)
Copy-Item .\ -Destination C:\NtfsTest\repo -ToSession $s -Recurse -Force
```

Two dependencies are **not** present on a clean Windows install and must be staged from the host, because the guest has no internet:

| Dependency | Needed by | Failure if missing |
|---|---|---|
| .NET 9 Runtime | MFTECmd | Clear message |
| VC++ 2015–2022 x64 | mft_dump | **Silent** — exits `0xC0000135`, no output |

`Get-Tools.ps1` downloads both. Install them in the guest:

```powershell
Start-Process .\tools\dotnet-runtime-9-win-x64.exe -ArgumentList '/install','/quiet','/norestart' -Wait
Start-Process .\tools\vc_redist.x64.exe -ArgumentList '/install','/quiet','/norestart' -Wait
```

In the guest, elevated:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\provision\New-TestVolumes.ps1 -Force
.\provision\Set-AmbientConfig.ps1 -Mode CleanRoom
```

`-Scope Process` is deliberate — it avoids changing the guest's persistent execution policy.

## 5. Run

```powershell
.\harness\Invoke-FullRun.ps1 -SettleSeconds 20
```

Each volume as primary, to confirm geometry has no effect:

```powershell
.\harness\Invoke-FullRun.ps1 -PrimaryVolume 'W:' -SecondaryVolume 'V:' -RunLabel 'vol_W256'
.\harness\Invoke-FullRun.ps1 -PrimaryVolume 'X:' -SecondaryVolume 'V:' -RunLabel 'vol_X64K'
.\harness\Invoke-FullRun.ps1 -PrimaryVolume 'C:' -SecondaryVolume 'V:' `
    -CaseRoot 'C:\NtfsTest\cases' -RunLabel 'vol_Cphys'
```

The `C:` run uses `-CaseRoot` because excluding an entire system volume from scanning is heavy-handed and looks like malware behavior to AV heuristics; a single named directory does not.

The ambient-condition runs — realistic baseline, and the indexed-location control — are described in [exceptions.md](exceptions.md) §G and [findings.md](../results/win11-25h2-26200.9168/findings.md) §6.

### Explorer cases

Eleven cases cannot be automated: Explorer needs an interactive desktop session. Perform them at the guest console following [explorer-test-plan.md](explorer-test-plan.md), twice, and compare the passes.

After a guest reboot, VHDX attachment does not persist:

```powershell
.\provision\Mount-TestVolumes.ps1
```

## Gotchas

**Explorer-driven tests need the console.** PowerShell Remoting sessions are non-interactive, so a manual pass runs at the guest console, and `Invoke-ExplorerTest.ps1` refuses to start one outside an interactive session. The automated pass runs over Remoting but acts on the console session, so the harness user must be logged on there with the desktop unlocked. See [explorer-test-plan.md](explorer-test-plan.md).

**The search indexer restarts itself.** `WSearch` is `Auto` with `DelayedAutostart`; stopping it does not keep it stopped. Verify in the fingerprint comparison rather than assuming. See [methodology.md](methodology.md).

**VHDX attachment does not survive a reboot** — run `.\provision\Mount-TestVolumes.ps1`.
