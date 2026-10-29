# Windows NTFS Timestamp Rules

[![Project Status: WIP](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> [!WARNING]
> **Active development.** Results are still being validated and may change. Testing of the current build is not complete — alternate data stream results and full system-component hashes are still outstanding. Not yet suitable for citation in casework or coursework.

## Project goals

Over the years, forensic analysts have successfully leveraged filesystem timestamps to help interpret activity relevant to their investigations. Each operating system, and even version of operating system, may apply timestamps in different ways. This project focuses specifically on Windows, aiming to create a reproducible test harness for documenting Windows NTFS timestamp behavior.

## What it answers

For common file operations (create, modify, copy, move, etc.), and for the most common methods used to perform them, the harness ([docs/methodology.md](docs/methodology.md)) documents what happens to all eight timestamps stored in the `$MFT`: Created / Modified / Access / MFT Entry Modified times for both the `$Standard_Information` and `$File_Name` attributes.

Results are published in two separate parts:

1. **Normal behavior** — results for ordinary files under ordinary circumstances, no tampering. The primary tables document what an analyst would see in the field under typical circumstances. See the [current findings](results/win11-25h2-26200.9168/findings.md).
2. **Common exceptions** — document conditions that can cause variations from the normal behavior. Examples include timestamp tampering (a.k.a. "timestomping"), cloud share synchronization, archival tool usage, and more. See [docs/exceptions.md](docs/exceptions.md).

## Results

**[results/win11-25h2-26200.9168/findings.md](results/win11-25h2-26200.9168/findings.md)** — the current results, for Windows 11 25H2. Additional results will be added as new major versions of Windows are released.

Each tested Windows version gets its own folder under `results/`, holding the findings, the environment fingerprint, the parsed output, and the archived `$MFT` files the conclusions were drawn from.

## Project layout

```
docs/
  methodology.md         how results are produced, and why each control exists
  exceptions.md          when these rules do NOT apply -- read before relying on them
  tooling.md             parsers used, their limitations, pinning
  provenance.md          installation media, build and component identification
  explorer-test-plan.md  manual procedure for the Explorer (GUI) cases
  setup-vmware.md        guest creation on VMware Workstation
  setup-hyperv.md        guest creation on Hyper-V
provision/
  Get-Tools.ps1          download + pin third-party parsers
  New-TestVolumes.ps1    create VHDX test volumes (hypervisor-agnostic)
  Mount-TestVolumes.ps1  reattach after reboot
  Set-AmbientConfig.ps1  clean-room vs realistic-baseline state
harness/
  NtfsTimestamps.psm1       live $SI read/write (all four values)
  Operations.psm1           the operation x mechanism generators
  Capture.psm1              $MFT extraction + multi-parser normalization
  Export-Mft.ps1            raw $MFT extraction with integrity gates
  Invoke-TimestampTest.ps1  the runner
  Invoke-ExplorerTest.ps1   runner for the Explorer (GUI) cases, manual or automated
  Invoke-ExplorerDriver.ps1 automated Explorer driver (real mouse/keyboard input)
  Compare-Results.ps1       classification + baseline diff
  Compare-Runs.ps1          cell-by-cell comparison of repeated runs
  New-ResultsReport.ps1     publishable Markdown report
  Invoke-FullRun.ps1        one-command full pass
  Update-RunSnapshots.ps1   re-parse archived $MFT without re-running the tests
  Get-EnvironmentFingerprint.ps1 / Compare-Fingerprint.ps1
tools/tool-hashes.json      pinned SHA256 of every third-party parser
expected/                   published baseline rule tables used for comparison
results/<build>/            fingerprint, archived $MFT, parsed output, findings
  charts/                   rule tables as PNG, plus the HTML they render from
```

## Design commitments

**Every result set records the environment that produced it.** A Windows build number alone does not identify the code under test: components are serviced independently, and timestamp behavior depends on the shell as much as on the filesystem driver. Each run captures a fingerprint (OS build, the versions and hashes of the relevant system components, and the ambient filesystem settings) and stores it with the results. The fingerprint is captured again when the run finishes. If anything changed partway through, the run is marked invalid rather than explained. This is what makes results from different Windows versions comparable as the project grows. See [docs/provenance.md](docs/provenance.md).

**At least two independent parsers read every timestamp.** MFTECmd (C#) and Velociraptor (Go) both cover all eight, while mft_dump (Rust) covers six (it cannot see MFT Entry Modified). Tool disagreement is reported. See [docs/tooling.md](docs/tooling.md) for each parser's limitations and how versions are pinned.

**The hypervisor is not part of the test apparatus.** Any hypervisor that can run modern versions of Windows should work. Test NTFS volumes are VHDX files created inside the guest VM, which needs no Hyper-V role. A control run on a physical-backed system volume produces results identical to the VHDX volumes. So, the same procedure reproduces on VMware, Hyper-V, VirtualBox or bare metal.

**Differences due to volume geometry and size are measured, not assumed.** The full matrix runs four times, each with a different volume as primary: 64 GB and 256 GB (testing the historical 128 GB threshold), 4K and 64K clusters, VHDX and physical backing. The rule tables generalize rather than describing one configuration, unless differences are observed.

**Archived `$MFT` files are the evidence.** Each run keeps its extracted `$MFT` files, a `run.json` holding their SHA256 and every parser's reading of each case, and the classifier output, so a third party can re-derive the conclusions. The one gap is the `C:` system volume, whose 277 MB `$MFT` exceeds GitHub's file size limit; for the three runs that used it (`indexed01`, `noindex01`, `vol_Cphys`), the parsed records in `run.json` are archived instead.

## Before relying on these tables

Read [docs/exceptions.md](docs/exceptions.md). The rules describe a specific tested configuration. Application behavior, such as the temp-file-and-rename save path used by Office and most editors, accounts for the majority of apparent rule violations on real systems, and access paths such as WSL, SMB and Dev Drive (which is ReFS, not NTFS) are currently outside the project's scope.

## Running the harness yourself

Most visitors will only want to review the test results. To reproduce them, the recommended path is to build a test VM following [docs/setup-vmware.md](docs/setup-vmware.md) or [docs/setup-hyperv.md](docs/setup-hyperv.md), then run `harness/Invoke-FullRun.ps1`. The Explorer cases are performed by hand, with an additional automated pass compared against them; see [docs/explorer-test-plan.md](docs/explorer-test-plan.md).

## Third-party tools

Only open-source tools are used for MFT analysis. `provision/Get-Tools.ps1` downloads pinned versions and verifies them against `tools/tool-hashes.json`, aborting on mismatch. Each tool is the property of its respective authors and carries its own license.

## License

MIT — see [LICENSE](LICENSE). Third-party tools are not redistributed here; each remains the property of its respective authors under its own license.
