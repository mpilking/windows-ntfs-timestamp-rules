# Methodology

This document aims to describe how the results were produced in enough detail to verify findings and/or create test results for other Windows builds.

## The core test procedure

Every core result is produced the same way, and this is the definition the published rule tables rest on:

> **Create a brand-new file. Perform exactly one operation on it. Record the effect on all eight timestamps. Discard that file and start over with a new one for the next operation.**

No file is ever used for two operations. A file that was renamed is not then copied; a file that was accessed is not then modified. Each cell in the rule tables comes from a file whose entire history is: created, then subjected to the single operation that cell describes.

This matters because timestamp effects compound. If one file were walked through access → modify → rename → copy, every result after the first would carry the residue of the operations before it, and no cell could be attributed to its own operation. The harness enforces the rule structurally: each case gets its own freshly created file inside its own freshly created directory, and the runner has no path by which one case's output becomes another's input.

Three consequences follow, each implemented rather than assumed:

- **`file_create` is tested like any other operation.** Its subject must not
exist when the "before" snapshot is taken, so for creation cases the runner makes only the containing directory during setup and performs the creation itself during the measured phase. Every other case has its subject file already in place before measurement begins.
- **Destination directories are pre-created.** For copy and move cases the
target directory is made during setup, so the directory's own creation never lands inside the measured window of the operation under test.
- **Each case gets a unique name in a unique directory.** This is required by
file tunneling (see below), not merely tidy.

### Core vs. variation

A core result uses one canonical mechanism per operation — the ordinary way to perform it. Other mechanisms (`xcopy`, `robocopy`, .NET, `cmd`) run as well and are reported as **mechanism variations** in their own section, never averaged into the core table. Where a variation differs, it is tool behavior rather than an NTFS rule and belongs on the exceptions list.

The canonical choice does not change any core value: every mechanism tested agreed per operation except robocopy, which is documented as exception D7. The variations section states this explicitly each run, so the claim is re-verified rather than inherited.

### Core vs. edge cases

The **core** result set is the normal condition only: ordinary files, no prior tampering. Timestomping is an **edge case**, run as its own condition and reported separately. The two are never merged, and a mechanism visible only under timestomping is reported as mechanism, not as a normal observable.

## Design principles

**The mechanism is a variable, not a detail.** The published 22H2 charts show a cross-volume move setting `$SI` Creation to the time of the move via CLI, but *inheriting* it via Explorer cut/paste. The same logical operation, two different results. Every operation is therefore run through every mechanism we can script, and a result that varies by mechanism is reported per mechanism rather than averaged into one cell.

**Two conditions, reported separately.** The `normal` condition (ordinary files, no prior tampering) produces the primary rule tables. The `timestomped` condition is a separate finding set. A mechanism visible only under timestomping is reported as mechanism, never promoted into the normal table — see [Why two conditions](#why-two-conditions).

**Nothing is trusted to one tool.** Every timestamp is read by at least two independent parsers written in different languages. Disagreement is a finding, not something to round away. See [tooling.md](tooling.md).

**The environment is measured, not assumed.** A fingerprint is captured before and after every run and the run is invalidated if anything moved. Results are keyed on the whole environment fingerprint -- component hashes plus ambient filesystem settings -- not on a build number. See [provenance.md](provenance.md).

## Why two conditions

On a normally created file, `$SI` and `$FN` hold identical values. Two different hypotheses — "`$FN` was left unchanged" and "`$FN` was repopulated from `$SI`" — therefore predict **exactly the same observation**, and no amount of careful measurement on a normal file can separate them.

The timestomped condition sets `$SI` to four distinct historical values before the operation:

| Field | Value |
|---|---|
| Creation | 2019-01-01 01:01:01 |
| Modified | 2019-02-02 02:02:02 |
| Access | 2019-03-03 03:03:03 |
| MFT Entry Modified | 2019-04-04 04:04:04 |

Distinct per field, so a resulting value is individually attributable: if `$FN` Modified comes back as 02-02 it came from `$SI` Modified specifically, not from "some `$SI` value".

It also helps with **access times**, for a different reason. NTFS updates Access in memory on every access but defers the write to the `$MFT`, so a `$MFT`-derived "Access did not change" could be a value that has not landed yet. Setting Access to 2019 makes any update conspicuous: the value either moves to something recent or it does not, with no ambiguity about which recent value it should have been. The authoritative control for Access is still the live Win32 read described under [Capture](#capture); the historical value simply makes a change unmistakable when the `$MFT` is examined.

Writing all four `$SI` values requires `NtSetInformationFile`; the common `SetFileTime` API cannot write Entry Modified, which is also why many public timestomping tools leave that value behind as an indicator.

## Run structure

The harness runs on a **host** machine and drives the **guest** VM over PowerShell Remoting: scripts are copied into the guest, invoked there, and the results copied back. Nothing in the automated path requires anyone to be logged on at the guest console. The Explorer cases are the sole exception, for the reason given below.

Five phases, in an order that is not stylistic:

1. **Setup** — one uniquely named file per case, in its own uniquely named
directory. Apply the timestomp precondition to the timestomped variant.
2. **Before** — one `$MFT` snapshot per volume.
3. **Execute** — perform each operation, spaced by `-SettleSeconds`, and read
the **live `$SI` immediately after each one**. **Delete cases run last.**
4. **After** — pause for `-PostRunSettleSeconds` (default 180), then take one
`$MFT` snapshot per volume.
5. **Late** (optional, `-LateCaptureMinutes 65`) — re-snapshot after the
deferred-write window has elapsed. Any value that moved between phase 4 and phase 5 reached disk late and was not a stable rule at capture time.

### Why these orderings

**Unique names per case.** NTFS file tunneling caches a deleted or renamed file's creation time for ~15 seconds, keyed on **name + directory**, and reapplies it to a new file of the same name. Reusing a name across cases could transplant one case's creation timestamp into the next, and the result would look entirely plausible.

**Deletes last.** The deleted record is read *after* the file is gone, and NTFS recycles deleted records. A copy executed afterwards can claim the record a delete case needs read.

**Two snapshots per volume, not per case.** Nothing mutates between setup and execute, so per-case extraction costs a great deal and buys nothing.

**Spacing must exceed twice the tolerance.** Otherwise a file's creation time falls inside its operation's comparison window, `NO_CHANGE` and `OP_TIME` become indistinguishable, and every cell reports as ambiguous for reasons unrelated to NTFS. `Compare-Results.ps1` warns when this is violated.

## Explorer cases

Explorer operations need an interactive desktop session, and both PowerShell Remoting and PowerShell Direct are non-interactive. The Explorer cases are therefore performed two ways, following [explorer-test-plan.md](explorer-test-plan.md):

- **By hand** at the guest console, at least twice. These manual passes are the reference.
- **By an automated driver**, as an additional test. `Invoke-ExplorerTest.ps1 -Driver Automated`, run over Remoting, launches `Invoke-ExplorerDriver.ps1` in the logged-on user's desktop session through a scheduled task with an interactive token. The driver opens folder windows and locates files with Shell COM and UI Automation, then performs each operation with real mouse and keyboard input, so Explorer follows the same code path it does for a person. Every step verifies that it happened, and a case that cannot be verified is failed rather than classified.

The two must agree cell for cell, and `Compare-Runs.ps1` lines them up. A disagreement is investigated, not averaged.

`Invoke-ExplorerTest.ps1` keeps everything else identical for both. It stages the cases, takes the before snapshots, has each operation performed, then takes the after snapshots and writes the same `run.json` the automated runner produces — so `Compare-Results.ps1` and the report generator consume it unchanged. In a manual pass an Enter keypress brackets each operation. Those windows measured 7 to 86 seconds on 25H2, against 0.1 to 3.1 seconds for the driver. Despite that difference, the automated pass agreed with both manual passes on all 88 cells.

Three constraints the plan enforces:

- **Run on a non-indexed volume.** Windows Search updates `$SI` Access on files
in indexed locations about a second after any change, which would be indistinguishable from an Explorer-caused update. `V:` and `W:` are outside the default crawl scope; `C:\Users\` is not.
- **Record where the file ended up.** Explorer may rename or relocate it in
ways the harness cannot predict, so the operator supplies the resulting path. Quotes from Explorer's "Copy as path" are stripped on input. The driver instead checks the path it expects, and identifies a recycled file's `$R…` name from its `$I` record.
- **Resolve by entry number where the name is unpredictable.** A Recycle Bin
delete moves the file into `$Recycle.Bin` *and* renames it to `$R…`, so the runner records each case's MFT entry number before the manual phase and the classifier falls back to it. That fallback is blocked for copy and cross-volume move, where the source record survives and would be matched instead of the result.

Because a manual pass cannot be repeated cheaply, it is run (at least) **twice** and the passes compared cell-for-cell.

## Capture

`$MFT` is extracted with TSK `icat` and parsed offline. Before every extraction the volume is flushed (`fsutil volume flush`) because NTFS updates MFT records lazily and a raw read taken immediately after an operation can return the pre-operation record.

**A flush does not force a pending Access update onto disk.** Measured on the "win11-22h2-26200.9168" build: a file read at 19:39:01 had that value on disk immediately, but a second read four minutes later moved the live value to 19:43:02 while the `$MFT` still reported 19:39:01 — *after* an explicit `fsutil volume flush`. The explanation is that NTFS holds the new Access time in the in-memory file control block and has not yet written it into the MFT record, so there is no dirty page for a flush to commit. Flush writes what is already dirty; it cannot pull a value out of the FCB.

The consequence for this study is narrow but important. An Access time read from the `$MFT` is a **lower bound** on when the file was last accessed, not necessarily an exact moment, and a measured "Access did not change" could in principle be an update that has not landed yet. Where that distinction matters — notably the finding that rename and local move do not write Access — the claim rests on a **live Win32 read taken immediately after the operation**, which reflects the in-memory value and so cannot be stale. In those tests the live value never moved, meaning nothing was pending.

Creation, Modified and Entry Modified are not subject to this: they are written as part of the operation's own record update.

> **Extraction hazard.** `icat ... > out.bin` corrupts the `$MFT` under PowerShell: the redirection operator treats native stdout as text and re-encodes the stream. A 262,144-byte `$MFT` came back as 524,336 bytes with a `??F ` signature instead of `FILE`. `Export-Mft.ps1` copies the raw stream to a `FileStream` and hard-fails on a bad signature or a size that is not a multiple of the 1024-byte record size.

## Classification

Each observed value is labelled against the operation's tolerance window rather than tested for equality: a manual operation and a scripted one both span a measurable interval, and a value landing anywhere inside it was written by that operation. Exact-tick questions are handled by the separate checks below.

| Label | Meaning |
|---|---|
| `OP_TIME` | inside the operation's window (± tolerance, default 2 s) |
| `NO_CHANGE` | identical to the pre-operation value |
| `INHERITED` | equals the source file's pre-operation value for the same field |
| `PREV_SI_*` | equals the source's pre-operation `$SI` value for a named field |

`NO_CHANGE` is **not** evaluated for copy or cross-volume move: those produce a new record that had no prior value, so "unchanged" is not a coherent claim, and testing it compares the new file against the source — which is what `INHERITED` already tests.

The classifier returns **every** label that fits and marks a cell `AMBIGUOUS` when more than one survives. Ambiguity is reported, not resolved.

**Why 2 seconds.** The tolerance (`-ToleranceSeconds`) was set from the data. Across every 25H2 run, no value an operation wrote fell more than a millisecond outside its bracketed window, so 2 s is a wide margin. Every value further out came from Windows Search on an indexed path, up to about 2 s after the operation. An earlier 5 s default credited two of those to robocopy; at 2 or 3 s, no verdict in any other run changes.

### Three checks the verdict labels cannot make

`OP_TIME` uses a two-second tolerance window, so by construction it cannot distinguish *the operation wrote this value* from *something else wrote it a second later* — nor can any `$MFT`-only comparison tell a value that did not change from one that has not been written yet. Three exact-tick analyses run alongside the classifier for these reasons, each emitting its own CSV.

**Live vs `$MFT`** (`pending-writes.csv`). Each case records the live `$SI` read taken immediately after its operation. Where that disagrees with the parsed `$MFT`, the write had not yet reached disk; the live value is authoritative because it is the in-memory record. Reported rather than silently classified, since the failure mode is a false `NO_CHANGE` — which looks exactly like a finding. See [Capture](#capture) for why a flush does not prevent this.

**Access vs Entry Modified** (`access-vs-entrymodified.csv`). A value written by an operation is part of the same MFT record update, so it matches `$SI` Entry Modified **exactly**. Each case is classified:

| Class | Meaning |
|---|---|
| `EXACT` | Access == Entry Modified — written by the operation |
| `TRAILS` | Access 0–30 s **after** — a third party wrote it afterwards |
| `PRECEDES` | Access older — the operation did not touch it |
| `LATE` | far later, or Entry Modified inherited from a source file |

Validation across three runs that differ only in whether the indexer was active:

| Run | indexer | `TRAILS` | `EXACT` |
|---|---|---|---|
| indexed location | running | **36** | 0 |
| same location | disabled | 0 | 26 |
| clean room | stopped | 0 | 26 |

No false positives on either control. This check is what established that rename does not write Access even on an indexed volume — the indexer does, roughly a second later.

**Sub-second precision** (`precision-analysis.csv`). NTFS stores 100 ns granularity, so a genuine value is almost never round. `LossyRestore` flags a value whose fraction went from present to zero within the same second — software that read the file and then wrote a reconstructed timestamp back. Measured 0 for both Defender and Windows Search; retained because the behavior is reported in other products.

Two things this check does **not** mean. It is not an API limitation: `SetFileTime` takes a `FILETIME` and preserves the full 100 ns fraction, verified here by writing `…03:03:03.1234567` and reading it back exactly from both the live record and the `$MFT`. A fraction is lost only when the caller supplies a whole-second value — a parsed date string, or a round-trip through `SYSTEMTIME` (ms) or `time_t` (s). And the inference is one-directional: a realistic fraction proves nothing, because a tool can supply one just as easily.

> Storing timestamps correctly is a precondition for both checks. Values are held as round-trip ISO 8601 strings, never as `DateTime` objects: PowerShell 5.1 serialises a `DateTime` to JSON as `/Date(<ms>)/`, truncating to milliseconds, and interpolating one into a string drops the fraction entirely. Either path silently destroys the detail these analyses depend on.

## Test volumes

Created as VHDX files from inside the guest via `Mount-DiskImage` / `diskpart`, which need no Hyper-V role. The hypervisor is therefore not part of the apparatus; the same provisioning script yields byte-identical geometry on VMware, Hyper-V, VirtualBox or bare metal.

| Volume | Size | Cluster | Backing | Purpose |
|---|---|---|---|---|
| `V:` | 64 GB | 4K | VHDX | under the historical 128 GB threshold |
| `W:` | 256 GB | 4K | VHDX | over the threshold |
| `X:` | 64 GB | 64K | VHDX | isolates cluster size from volume size |
| `C:` | 999 GB | 4K | VMware virtual disk | VHDX-transparency control |

`V:` vs `W:` varies volume size; `V:` vs `X:` varies cluster size. Without the third volume the two factors are confounded and "small volumes behave differently" would be uninterpretable.

**Each volume carries the complete matrix as the primary volume.** It is not enough to run everything on one volume and use the others only as move destinations — that tests the destination role, not the volume. Results are compared cell-for-cell against the `V:` baseline.

`C:` is the one run that places case directories in a subdirectory (`-CaseRoot C:\NtfsTest\cases`) rather than at the volume root. Excluding an entire system volume from scanning is both heavy-handed and indistinguishable from malware behavior to AV heuristics; a single named directory is neither. Path depth does not affect timestamp rules, so results remain comparable.

**8.3 short names are forced ENABLED on every test volume.** Modern Windows disables 8.3 creation on non-system volumes at format time while leaving it enabled on the system volume, so a file on `C:` normally carries **two** `$FILE_NAME` attributes while the same file on a secondary volume carries one. Left at the default, every `$FN` short-name case would have been silently untested.

## Ambient state

Defender **exclusions** are applied to the test volumes rather than disabling real-time protection, so the machine stays in a normal running state while the experimental path is isolated. OneDrive and the search indexer are stopped.

A second **realistic baseline** pass runs with defaults and no exclusions; the delta is the measured noise floor of a stock install. See [exceptions.md](exceptions.md) §G.

### Stopping the search indexer is not durable — and did not matter

`WSearch` ships as `Auto` with `DelayedAutostart`, and Windows restarts it on demand. Stopping it before a run does **not** keep it stopped: the fingerprint comparison recorded it restarting partway through **four of the first six runs**, each flagged as a warning:

```
| WARNING | InterferingAgents | MpDefenderCoreService, MsMpEng | SearchIndexer |
```

This is reported rather than quietly corrected, because the evidence that it did not affect results is stronger than the control that was supposed to prevent it:

- **Every run produced identical results**, including those in which the
indexer stayed stopped throughout. Had the indexer been opening test files, the runs would have diverged.
- The specific thing an indexer would disturb is **access time**, and
"`$SI` Access does not change on rename or local move" is one of the published findings — reproduced in every run, with and without the indexer active.
- Freshly created VHDX volumes are not added to the default crawl scope, and
`C:\NtfsTest\cases` is not a default indexed location, so the indexer had no reason to touch the test files in the first place.

The Defender **exclusions** are the control that actually holds, since they are configuration rather than process state. Treat the indexer stop as belt-and-braces, verify it in the fingerprint comparison rather than assuming it, and do not claim a clean room the data cannot support.

`Set-AmbientConfig.ps1 -ExclusionsOnly` exists because the two modes are not inverses: `RealisticBaseline` removes exclusions **and restarts the indexer**, so using it merely to drop an exclusion would silently contaminate the next clean-room run.

## Reproducing

### PowerShell Remoting to a standalone guest

The guest is a workgroup machine, not domain-joined, so remoting needs two things set up. Full guest-build steps are in [setup-vmware.md](setup-vmware.md) / [setup-hyperv.md](setup-hyperv.md); these are the parts the harness depends on.

On the **guest**, elevated:

```powershell
Enable-PSRemoting -Force
```

That starts WinRM, sets it to start automatically, creates the listener and adds the firewall rule. It **refuses if any network connection is on the Public profile** — a host-only adapter often comes up Public, so check first and set it to Private:

```powershell
Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceAlias 'Ethernet0' -NetworkCategory Private
```

On the **host**, add the guest to `TrustedHosts`. Without a domain there is no Kerberos, so NTLM requires the client to trust the target explicitly:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<guest-ip>' -Force
```

Then connect with a **local** admin account on the guest for elevated execution (raw volume reads and VHDX attach both require it):

```powershell
$cred = Get-Credential            # VM admin account
$s    = New-PSSession -ComputerName <guest-ip> -Credential $cred
```

> Use a throwaway credential. The guest is an isolated lab VM on a host-only network; never reuse a real one, and never commit one to a repository.

Hyper-V can skip all of this and use **PowerShell Direct** (`New-PSSession -VMName …`), which needs no network, no listener and no `TrustedHosts` entry.

### Running

```powershell
.\provision\Get-Tools.ps1                      # on a host with internet
# stage tools to the guest, then:
.\provision\New-TestVolumes.ps1 -Force
.\provision\Set-AmbientConfig.ps1 -Mode CleanRoom
.\harness\Invoke-FullRun.ps1 -SettleSeconds 20
```

Confirmation pass, allowing deferred writes time to reach disk:

```powershell
.\harness\Invoke-FullRun.ps1 -SettleSeconds 20 -LateCaptureMinutes 65
```

After a guest reboot, reattach the volumes first:

```powershell
.\provision\Mount-TestVolumes.ps1
```
