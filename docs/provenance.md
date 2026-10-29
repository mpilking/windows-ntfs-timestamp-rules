# Provenance

Each tested OS includes a `fingerprint.json` file in its corresponding `results` directory. The fingerprint file's purpose is to document the OS components that could most likely influence a result, such that a third party can effectively rebuild an equivalent test environment rather than trusting our general description of it. The sections below describe the details that are tracked and some of the reasons for doing so.

## Installation media

Test systems are always installed using media sourced directly from Microsoft. For example, the media for the "Windows 11 25H2" tests are described as follows:

| Field | Value |
|---|---|
| ISO filename | `Win11_25H2_English_x64_v2.iso` |
| Source | Microsoft (official download) |
| Downloaded | 2026-08-27 |
| SHA256 | `768984706B909479417B2368438909440F2967FF05C6A9195ED2667254E465E3` |

## Why the Windows version name is not sufficient

A Windows major version name such as "Windows 11 25H2" is useful for generally describing a release of a Windows. However, it does not fully describe all aspects of the underlying code. A better representation of the installation is the full OS build number, which consists of four parts, such as `10.0.26200.9168`. `10.0` is the base kernel version, used for both Windows 10 and Windows 11. The third part is the **build**, fixed for a feature release (26200 = 25H2). The fourth is the **UBR**, or Update Build Revision, which increments with every cumulative update. The build and UBR numbers live in the registry:

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion
    CurrentBuildNumber = 26200
    UBR                = 9168
```

So "Windows 11 25H2" describes dozens of distinct binary states, and even "build 26200.9168" does not fully pin the individual components, as they may update independently. For example, the most relevant binaries on the reference VM for the "Windows 11 25H2" tests with OS build 26200.9168 were at the following version levels:

| Component | FileVersion |
|---|---|
| `ntfs.sys` | 10.0.26100.**1** |
| `ntoskrnl.exe` | 10.0.26100.**9168** |
| `explorer.exe` | 10.0.26100.**8117** |
| `shell32.dll` | 10.0.26100.**8972** |
| `windows.storage.dll` | 10.0.26100.**8972** |
| `SearchIndexer.exe` | 7.0.26100.**9168** |

Six components, six different revisions, serviced independently. (They report `26100` — the 24H2 base branch — because 25H2 ships as an enablement package over 24H2 servicing.) Although it's difficult to fully document all components that could affect timestamp behavior, we attempt to track those that are most likely to contribute.

## Beyond the NTFS driver

Worth noting, timestamp outcomes depend on **the caller** as much as on the NTFS driver. For example, as measured on the "Windows 11 25H2" tests:

- A cross-volume move via **Explorer** inherits `$SI` Creation; the same move via **CLI** sets it to the move time. Identical `ntfs.sys`, but different results.
- **Opening** a file from Explorer updates MFT Entry Modified if the file has no object ID yet; a programmatic (CLI) read does not. That is the shell, which gives the file an object ID for its Recent Items shortcut, not the filesystem.
- **Windows Search** updates Access time on files it crawls, typically about a second after any change.

None of those live in `ntfs.sys`, and any of them could change in an update that leaves the driver untouched.

**Consequence:** results are keyed on the **whole environment fingerprint**.

## Beyond component versions

Binary hashes alone do not describe a test environment. The fingerprint also records the settings and conditions that change results on otherwise identical binaries:

| Recorded | Why it matters |
|---|---|
| **Last access updating** (`fsutil behavior query disablelastaccess`, and the registry value behind it) | When disabled, Access times stop updating entirely. Windows has shipped different defaults across versions, so this must be read rather than assumed. |
| **File tunneling** (`MaximumTunnelEntries`, `MaximumTunnelEntryAgeInSeconds`) | NTFS briefly caches the creation time of a deleted or renamed file and reapplies it to a new file of the same name, which can make a new file appear older than it is. |
| **8.3 short name creation** (per volume) | Determines whether a file carries one `$FILE_NAME` attribute or two. Enabled on system volumes, disabled by default on others. |
| **Volume geometry** | Size, cluster size, NTFS on-disk version and drive letter for every volume under test. |
| **Interfering processes** | Which sync clients, AV and indexer processes were running. Windows Search in particular updates Access on files it crawls. |
| **Installed updates** | The most recent updates present, so a behavior change can be matched against what was patched. |
| **Parser versions** | Version and SHA256 of every analysis tool used, so output can be attributed to a specific build. |
| **Host context** | Edition, time zone, whether the system is virtualized, and whether the harness ran elevated. |

Anyone rebuilding an equivalent environment should match the first three in particular. Last access updating and tunneling both alter the results directly, and a mismatch there will look like a behavior difference in Windows rather than a difference in configuration.

## Harness version

Each `run.json` also records the harness that produced it. Every harness and provision script is hashed (SHA256, with line endings normalized to LF so a Windows and a Linux checkout of the same commit agree), and the set is reduced to a single digest. The git commit is recorded too when the run starts from a checkout. Recomputing the digest from a clean checkout with `Get-HarnessProvenance` (in `harness/Capture.psm1`) confirms which version of the scripts a result came from.

## Run validity

A fingerprint is captured immediately before the first operation and again immediately after the last. `Compare-Fingerprint.ps1` diffs them and fails the run if any components changed partway through.

## Hypervisor independence

Test volumes are VHDX files created and attached from *inside* the guest via `Mount-DiskImage` / `diskpart`, which require no Hyper-V role. The hypervisor is therefore not part of the experimental apparatus and is recorded only as context. See `setup-vmware.md` and `setup-hyperv.md`.

One assumption is validated in-band rather than assumed: a control case runs an identical operation set against the guest's physical-backed `C:` and against a VHDX test volume (e.g. a test volume mounted as `V:`). Matching results confirm the VHDX substrate is transparent to NTFS timestamp behavior.
