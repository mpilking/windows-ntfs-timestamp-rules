# Exceptions and Caveats for Analysts

A timestamp rule table describes what happened **in the tested configuration**. This register lists the conditions under which an observed timestamp may not match the published rule. An analyst reasoning from the tables should check this list before concluding that a timestamp is anomalous — or that it is normal. That said, this list is not fully exhaustive and likely will evolve over time.

Status values:

| Status | Meaning |
|---|---|
| `CONTROLLED` | Held to a fixed, recorded value during testing. Recorded in the run fingerprint. |
| `TESTED` | Explicitly varied as a test axis; results published. |
| `NOT TESTED` | Outside scope. Behaviour unknown. Do not extrapolate. |

---

## A. Environment provenance

| # | Exception | Status |
|---|---|---|
| A1 | **Host OS upgraded in place.** Settings configured under a previous build can persist across a feature upgrade. `DisableLastAccess`, tunneling registry values, and 8.3 configuration are not reset by an upgrade. A machine upgraded 22H2 → 25H2 may behave unlike a clean 25H2 install. | `CONTROLLED` (clean install from hashed ISO) |
| A2 | **Volume formatted by an older Windows version.** The NTFS on-disk structure version is fixed at format time. A volume created under Windows 7 and carried forward retains that format under Windows 11. | `CONTROLLED` (volumes formatted by the test build) |
| A3 | **Same OS build, different binaries.** A cumulative update can replace system components while `CurrentBuildNumber` is unchanged — only the UBR moves — and those components are serviced independently of one another, so their versions do not advance together. Timestamp behaviour depends on the shell and the search indexer as much as on the filesystem driver, so a build number alone does not identify the code that produced a result. See `provenance.md`. | `CONTROLLED` (results keyed on the full environment fingerprint, including component hashes) |
| A4 | **Enterprise policy baselines.** Group Policy, STIG/CIS hardening, or MDM can alter last-access updating, 8.3 name creation, and tunneling. Corporate endpoints frequently differ from defaults. | `CONTROLLED` (workgroup, no GPO) |
| A5 | **OEM images.** Vendor images ship non-default filesystem settings. | `NOT TESTED` |

## B. Access paths not exercised

Every rule in the tables was produced by a Win32 or shell operation issued locally. Other paths reach NTFS through different code and may not obey them.

| # | Exception | Status |
|---|---|---|
| B1 | **WSL / WSL2.** WSL1 reaches NTFS through DrvFs with Linux semantics layered on; WSL2 crosses a 9P/virtio-fs boundary. Linux tooling (`touch`, `mv`, `cp`, `git`) invoked against `/mnt/c` does not follow the Win32 rules. | `NOT TESTED` |
| B2 | **SMB / network shares.** The redirector and the server-side filesystem both participate. Remote operations may not reliably follow local rules (although they often do). | `NOT TESTED` |
| B3 | **Docker Desktop bind mounts / NFS client.** Additional translation layers. | `NOT TESTED` |
| B4 | **Dev Drive.** Windows 11 22H2+ Dev Drive is **ReFS, not NTFS**. It has no `$FILE_NAME` attribute in the NTFS sense and none of these rules apply. | `NOT TESTED` (out of scope) |
| B5 | **ReFS volumes generally.** | `NOT TESTED` (out of scope) |
| B6 | **FAT32 / exFAT.** Different on-disk format, 2-second granularity, local-time storage on FAT. | `NOT TESTED` (out of scope) |

## C. File types with special handling

| # | Exception | Status |
|---|---|---|
| C1 | **Cloud-synced files.** Files managed by OneDrive, Dropbox, Google Drive, Box and similar services can carry timestamps written by the sync engine rather than by local activity. A file may be re-dated when it syncs, or have a server-side timestamp restored over a local change. The behaviour differs between services, and can differ between versions of the same client, so no single rule covers them. On a synced folder, treat timestamps as evidence of sync activity as much as user activity. | `NOT TESTED` (out of scope; sync clients excluded during runs) |
| C2 | **More than one path to the same data.** A **hard link** is an additional name for the *same* MFT record, so every name shares one set of timestamps: an operation through one path changes what is seen through all of them, and the timestamps give no indication which path was used. A **symbolic link or junction** is the opposite — a separate record, with its own timestamps, that redirects to a target; whether an operation lands on the link or on the target depends on the tool and the flags it uses. | `NOT TESTED` |
| C3 | **Alternate data streams.** An ADS is a second `$DATA` attribute on the same MFT record, so writing one modifies the file's record without changing anything visible. Measured on Win11 25H2: `$SI` **Modified, Access and Entry Modified all move to the time of the write**, while Creation and all four `$FN` values are untouched. The unnamed stream's content and size are unchanged, and neither the stream nor its size appears in a normal directory listing (`Get-Item -Stream *` reveals them). **So a file can show a recent Modified time with no visible change to its contents** — an anomaly with a perfectly ordinary cause. Both mechanisms tested (`Set-Content -Stream`, `cmd` redirect to `file:stream`) agreed. | **`TESTED`** (Win11 25H2) |
| C4 | **EFS-encrypted, NTFS-compressed, and sparse files.** | `NOT TESTED` |
| C5 | **Directories.** Rules were derived from files. Directory behaviour differs on several operations, and directory `$I30` index entries carry their own timestamp copies. | `NOT TESTED` (see E1) |

## D. Application behaviour that overrides the rules

These are the most common cause of a "rule violation" that is not a violation.

| # | Exception | Status |
|---|---|---|
| D1 | **Explicit timestamp setting.** Any process may call `SetFileTime` / `NtSetInformationFile`. Installers, archivers, build tools, `rsync`, `git checkout`, and `robocopy /COPY:T` all do this legitimately. | `NOT TESTED` |
| D2 | **Save-as-rename.** Office, many editors, and most atomic-save implementations write a temporary file and rename it over the original. What the user calls "modifying a document" is create + write + rename + delete on disk, so the resulting timestamps follow the **rename and creation** rules, not the modification rule. Expect `$SI` Creation to look recent on a file the user has owned for years — and note **file tunneling** may instead preserve the original creation time if the rename lands within the tunnel window (which is the primary purpose of the file tunneling feature). | `NOT TESTED` |
| D3 | **Archive extraction.** Archive formats commonly store the original timestamps of their members, and extraction restores them — so extracted files routinely carry timestamps predating the volume they sit on. **Modified** time is the one most often preserved, but creation time is sometimes preserved as well. What actually survives varies by format (ZIP, RAR, 7z, CAB, TGZ, bare gzip, etc.) and by the tool used both to create *and* to extract the archive (WinZip, WinRAR, 7-Zip, `tar`, `Expand-Archive`, etc.). Treat the result as tool-dependent rather than assuming one rule covers all of them. | `NOT TESTED` |
| D4 | **Backup and imaging software** using backup semantics (`FILE_FLAG_BACKUP_SEMANTICS`) restores original timestamps. | `NOT TESTED` |
| D5 | **Windows Search updates `$SI` Access on indexed files.** Measured on Win11 25H2 with a four-condition control: files in an indexed location (`C:\Users\…`) had Access updated after **rename**, **local move** and even plain **creation**, where identical operations on a non-indexed path left it alone. Disabling the indexer and repeating against the same path restored the non-indexed result exactly. **A changed Access time on a file in an indexed location is not evidence of user access.** Default scope is `C:\Users\` (excluding `AppData`) plus the Start Menu — secondary volumes are not indexed by default. | **`TESTED`** (Win11 25H2; see `findings.md` §6) |
| D5a | **Telling the indexer apart from the operation: Access trails Entry Modified.** A timestamp written in the operation's own record update matches `$SI` Entry Modified **exactly**. The Windows Search indexer arrives afterwards, leaving Access **+0.007 s to +1.03 s later** (measured). On a freshly created file this is stark: without the indexer all four `$SI` values are identical to the tick; with it, Creation/Modified/Entry Modified match and Access alone sits a fraction of a second ahead. A sub-second gap between Access and three otherwise-identical values is likely the indexer, not a user. | **`TESTED`** (Win11 25H2) |
| D5b | **Microsoft Defender did not affect timestamps.** A full run with real-time protection on and **no exclusions anywhere** produced results identical to the clean room. Defender opens files without perturbing them. This is a statement about Defender at this build, **not** about AV generally. | **`TESTED`** (Win11 25H2) |
| D5c | **A zeroed sub-second fraction means a timestamp was constructed, not copied.** NTFS stores 100 ns granularity and genuine values are almost never round, so a `.0000000` fraction is worth investigating. **It is not an API limitation:** `SetFileTime` takes a `FILETIME` and preserves the full fraction — verified here by writing `…03:03:03.1234567` and reading it back exactly, from both the live record and the `$MFT`. The fraction is lost only when the caller supplies a whole-second value, which is what happens when a tool parses a date string or round-trips through a lower-resolution type (`SYSTEMTIME` is milliseconds, `time_t` seconds). Software that reads the original `FILETIME` and writes it back unchanged preserves it exactly. The pattern is reported in some AV products that restore Access after scanning; **not** produced by Windows Search or Defender here, both measured at 0%. The inference runs one way only: a realistic fraction proves nothing, since a tool can supply one (nTimetools does — see D6), and sub-second analysis cannot separate indexer-caused Access updates from user activity because the indexer performs a genuine read. | `TESTED` (API precision verified; negative for Defender and Windows Search); `NOT TESTED` for third-party products |
| D6 | **Deliberate timestomping.** Tools reach different depths, and the depth determines which indicators survive. Tools built on the common `SetFileTime` API (e.g. Metasploit `timestomp`, Unix-style `touch` ports, many privacy cleaners) write only `$SI`, and only three of its four values — they **cannot write Entry Modified**, which is what leaves the classic "three `$SI` values predate Entry Modified" anomaly. Tools built on the undocumented `NtSetInformationFile` API, such as [nTimetools](https://github.com/limbenjamin/nTimetools), write **all four `$SI` values including Entry Modified** at 100 ns precision and need no privileged access. Neither of these methods reach `$FN`, which no Win32 API exposes. **Direct MFT manipulation can write `$FN` outright:** [SetMace](https://github.com/jschicht/SetMace) resolves the filesystem itself and writes records straight to the physical disk through a kernel-mode driver, covering `$SI`, `$FN` and the `$I30` index entries. It needs administrator rights, and on 64-bit Windows 6.x and later PatchGuard blocks its test-signed driver — so it requires booting with TESTSIGNING or disabling PatchGuard, states that are themselves conspicuous. **A rename or local move after timestomping achieves the same `$FN` result with none of that**: NTFS repopulates all four `$FN` values from the previous `$SI`, so forged times propagate into `$FN` with no special tooling. Measured here — see `findings.md` §3; described independently as "Method 2" in [Inversecos](https://www.inversecos.com/2022/04/defence-evasion-technique-timestomping.html). Both classic indicators therefore have benign causes *and* can be defeated deliberately, so neither is conclusive alone. Journal-based detection (`$UsnJrnl`, `$LogFile`) is the recommended alternative and is **outside the scope of this study**. | `TESTED` for the `$FN` repopulation mechanism — the harness's own precondition uses `NtSetInformationFile`, the same API; `NOT TESTED` for specific tools or journal-based detection |
| D7 | **robocopy does not behave like a normal copy.** Its default `/COPY:DAT` copies **D**ata, **A**ttributes and **T**imestamps, so the destination file **inherits** the source's `$SI` Creation and Access instead of receiving the time of the copy. Measured on Win11 25H2: `robocopy`, `robocopy /COPY:DAT` and `robocopy /MOV` all returned *inherited* where `copy`, `xcopy`, `Copy-Item` and `File.Copy` returned *time of operation*. A file copied with robocopy can therefore appear to predate its arrival on the volume — with no tampering involved. `/DCOPY:T` does the same for directories. **This is documented robocopy behavior, not a change in NTFS**, and it is an exception to the standard copy rules rather than a correction to them. | **`TESTED`** (Win11 25H2, build 26200.9168) |
| D8 | **Explorer gives files an object ID, which changes Entry Modified.** Opening a file from Explorer adds it to Recent Items, and the shortcut's link-tracking data identifies the file by its NTFS object ID. **If the file has no object ID yet**, one is created, which changes its MFT record and so `$SI` Entry Modified, even though the application only reads the file. That is typically the first time Explorer opens, renames or moves the file, whatever its age. Once a file has an object ID, from Explorer or anything else, opening it again changes Access alone. Measured on Win11 25H2: Explorer open, rename, local move and the destination of a cross-volume move all added an object ID; browse, copy, Recycle Bin delete and every command-line operation did not. **So an `$OBJECT_ID` on a file is consistent with Explorer having handled it**, though other software can create one too, and its absence proves nothing. The object ID's embedded GUID timestamp does not date the assignment. Not yet tested: whether turning off Recent Items, or stopping the Distributed Link Tracking Client service, prevents the Entry Modified change on open. | **`TESTED`** (Win11 25H2, Explorer cases and repeat open; see `findings.md` §7); `NOT TESTED` with Recent Items or link tracking disabled |

## E. Measurement and interpretation caveats

| # | Exception | Status |
|---|---|---|
| E1 | **`$I30` directory index copies.** The parent directory's index caches a copy of a file's timestamps. These are **not** guaranteed to match the file's own `$SI`, and tools that read directory listings may report different values than tools that parse the MFT record. Also, slack space in `$I30` commonly retains entries for deleted files. | `NOT TESTED` |
| E2 | **An Access time in the `$MFT` can lag the real last access time.** NTFS updates Access in memory on every access, but **delays writing it to the `$MFT` by up to an hour** so that each read operation does not immediately become a write operation to update the `$MFT`. Microsoft states it as "NTFS delays updates to the last access time for a file by up to one hour after the last access." Measured on the "win11-25h2-26200.9168" build: a file read at 19:39:01 showed that value on disk at once; a second read four minutes later moved the in-memory value to 19:43:02 while the `$MFT` still reported 19:39:01. **For an analyst, a `$MFT` Access time is a lower bound on the last access, not the exact moment** — the true access can be up to an hour later, and an access shortly before the `$MFT` acquisition may not appear at all. This is a delayed write, *not* a rule that ignores accesses: repeated reads minutes apart each updated the value. Note also that last-access updating can be disabled entirely; Windows 10/11 ships `System Managed` and the effective state has varied between builds, so read it from the host configuration rather than assuming. | `TESTED` (Win11 25H2) |
| E3 | **Lazy MFT writes, and the limits of flushing.** The in-memory record leads the on-disk record, so a raw `$MFT` read taken shortly after an operation can return stale values. `fsutil volume flush` commits what is already dirty but **does not force a pending Access update out of the file control block**. Measured on the "win11-25h2-26200.9168" build, an Access update was still absent from the `$MFT` after an explicit flush. Creation, Modified and Entry Modified were not affected, being written as part of the operation's own record update. | `CONTROLLED` for Creation/Modified/Entry Modified (flush before every capture); for Access, claims rest on a **live Win32 read taken immediately after the operation**, which cannot be stale |
| E4 | **File tunneling.** For ~15 seconds by default, NTFS caches the creation time (and short name) of a deleted or renamed file, keyed on **name + directory**, and reapplies it to a new file of the same name. This makes a newly created file appear older than it is if recreated quickly. | `CONTROLLED` (unique names per case) and `TESTED` |
| E5 | **MFT record reuse.** Deleted records are recycled. A record examined after deletion may already belong to a different file. | `CONTROLLED` (delete cases sequenced last) |
| E6 | **Clock changes.** NTP correction, manual changes, DST, and VM host time synchronisation can reorder timestamps relative to wall-clock expectations. All captures are recorded in UTC. | `CONTROLLED` |
| E7 | **Virtualisation substrate.** Results were produced on a VM with VHDX-backed test volumes. | `CONTROLLED` (validated against physical-backed `C:`) |

## F. Scope limits of this study

- Mechanisms tested are enumerated per operation in the results. A mechanism not
listed was not tested.
- Single local user, workgroup, no domain or roaming profile.
- Volume sizes and cluster sizes tested are recorded in the run manifest.
- Results apply to the specific build and component versions recorded in the
fingerprint. They are not a general statement about "Windows 11."

## G. Clean room vs. realistic baseline

Defender, Windows Search, and OneDrive are enabled by default on Windows, so disabling them produces an unrealistic machine. Leaving them running produces unreproducible results. These are not competing answers to one question — they are two different questions, and the study answers both.

**Pass 1 — clean room (authoritative).** Determines *what Windows does on a vanilla NTFS volume*. The test volumes are **excluded** from Defender and the indexer rather than the services being disabled, so the system remains in a normal running state while the experimental path is isolated. Any background process that touches a test file here would be published as an NTFS rule, which is the one error this study cannot afford. The rule tables come from this pass.

**Pass 2 — realistic baseline (characterisation).** Run once, with default services active and no exclusions, against an identical operation set. The delta against pass 1 is the measured noise floor of a stock Windows 11 install.

Pass 2 turns D5 from a qualitative caveat into a number for this specific build and Defender version. It does **not** redefine any rule; where the two passes disagree, pass 1 states the rule and pass 2 states what an analyst should expect to see on a live system. Cost is one extra run, not a doubled matrix.

---

## How to use this register

1. Confirm the observed system's configuration against the run fingerprint (`results/<build>/fingerprint.json`). Differences in section A invalidate direct comparison.
2. Determine how the file was actually touched. Section D accounts for the majority of apparent rule violations on real systems.
3. If the access path is in section B, the tables do not apply.
4. Treat a single anomalous timestamp as a question, not a conclusion. Look to other artifacts for corroboration.
