# Verification Tooling

No single parser is trusted. Each timestamp is read by at least two independent implementations, written in different languages by different authors, and a disagreement between them is treated as a finding.

## Roster

| Tool | Language | Input | Timestamps | Role |
|---|---|---|---|---|
| **MFTECmd** 2026.5.0 | C# | live locked `$MFT`, or extracted file | **8 of 8** | Primary parser |
| **Velociraptor** v0.77.2 | Go | extracted `$MFT` via `parse_mft()` | **8 of 8** | Automated second opinion |
| **mft_dump** v0.7.0 | Rust | extracted `$MFT` | 6 of 8 | Automated third check |
| **The Sleuth Kit** 4.15.0 | C | volume / disk | `$SI` + `$FN` | `$MFT` extraction (`icat`), offline volume-level check (`istat`) |
| **Mft2Csv** v2.0.0.51 | AutoIt | live volume, image, or `$MFT` | 8 of 8 | Pinned and available; **not used** in the published runs |
| Win32 `GetFileInformationByHandleEx` | — | live file | `$SI` 4 of 4 | Live read after every operation; authoritative for Access |
| NT `NtSetInformationFile` | — | live file | writes `$SI` 4 of 4 | Timestomp precondition |

## Known tool limitations

**mft_dump exposes 6 of 8 timestamps.** Its schema carries `StandardInfoCreated/LastModified/LastAccess` and `FileNameCreated/LastModified/LastAccess` but **no MFT Entry Modified for either attribute**. It therefore cannot verify the "Metadata" row of either rule table.

**Mft2Csv is GUI-driven, and was not used.** Its documented workflows are interactive (select volume, click *Start Processing*); no command-line interface is documented, so it cannot join the automated pipeline. It is downloaded and pinned by `Get-Tools.ps1` and remains available for manual corroboration, but no published result depends on it. Parser agreement in these results is **three-tool**: MFTECmd, Velociraptor and mft_dump.

**The Sleuth Kit cannot parse a standalone `$MFT` file.** It operates at the volume or disk-image level only. It is used to *extract* `$MFT` (`icat -f ntfs \\.\V: 0`) and for the offline volume-level pass, not as a file-level parser.

**Writing all four `$SI` values requires the NT native API.** The Win32 `SetFileTime` cannot write `ChangeTime` (MFT Entry Modified), so the timestomp precondition goes through `NtSetInformationFile(FileBasicInformation)` instead. This is also why most public timestomping tools leave Entry Modified behind as an indicator — see `exceptions.md`.

## Why a live read sits alongside the parsers

`$MFT` parsers report what is **on disk**, which for Access can lag reality. NTFS updates Access in memory on every access but defers writing it to the `$MFT` by up to an hour, and `fsutil volume flush` cannot force it out — the value is still in the file control block, so there is no dirty page to commit. An `$MFT`-only capture can therefore show a stale Access value, which reads as "did not change" and looks like a finding.

The runner closes this by reading the live `$SI` through `GetFileInformationByHandleEx(FileBasicInfo)` immediately after every operation, and storing all four values with the case. That read reflects the in-memory record and cannot be stale, so it is authoritative for Access. Handles open with `FILE_READ_ATTRIBUTES` only, never `GENERIC_READ`, so measuring a file does not update the Access time being measured.

`Compare-Results.ps1` compares the live value against the parsed `$MFT` and reports any disagreement as a **pending write** (`pending-writes.csv`) rather than classifying the stale value silently. Creation, Modified and Entry Modified are not affected — they are written as part of the operation's own record update — so the parsers remain authoritative for those.

## .NET's role: an operation mechanism, not a parser

.NET appears in the results as a **mechanism** — one of the ways an operation is performed — rather than as a way of reading timestamps. The `dotnet` mechanism column means PowerShell called the .NET method directly:

| Operation | Call |
|---|---|
| create | `[IO.File]::WriteAllText()` |
| access | `[IO.File]::ReadAllText()` |
| modify | `[IO.File]::AppendAllText()` / `WriteAllText()` |
| rename, move | `[IO.File]::Move()` |
| copy | `[IO.File]::Copy()` |
| delete | `[IO.File]::Delete()` |

Results for these sit alongside `cmd`, `xcopy`, `robocopy`, the PowerShell cmdlets and Explorer, and are what established that most rules hold regardless of mechanism.

.NET is **not** used to read timestamps for any published result. `FileSystemInfo` exposes only three of the four `$SI` values — it has no property for MFT Entry Modified — so every timestamp in the results comes from a `$MFT` parser.

## Runtime dependencies on a clean Windows install

Two of the analysis tools depend on runtimes that are not present on a stock Windows 11 installation. Because the test VM has no internet by design, both must be downloaded on the host and staged to the guest alongside the tools; `Get-Tools.ps1` pins and retrieves them with everything else.

| Dependency | Needed by | Failure mode if missing |
|---|---|---|
| .NET 9 Runtime (`Microsoft.NETCore.App 9.0`) | MFTECmd | Clear message: "You must install .NET to run this application." |
| VC++ 2015–2022 Redistributable x64 | mft_dump | **Silent.** Exits `0xC0000135` with no output and a zero-byte result file. |

## Extraction hazard

`icat ... > out.bin` **corrupts the `$MFT`** under PowerShell. The redirection operator treats native stdout as text, inserting a BOM and re-encoding the stream. Observed here: a 262,144-byte `$MFT` came back as 524,336 bytes with a `??F ` signature instead of `FILE`.

`harness/Export-Mft.ps1` copies the raw stdout stream to a `FileStream` and hard-fails if the result lacks the `FILE` signature or is not a multiple of the 1024-byte record size.

## Parsers disagree on total record count — and that is not a defect

On the small VHDX test volumes the three parsers return near-identical record counts (measured: MFTECmd 164, Velociraptor 164, mft_dump 161). On a real system volume they diverge substantially. Measured on the 999 GB `C:` volume, same `$MFT` file, same moment:

| Tool | Records returned |
|---|---|
| MFTECmd | 326,362 |
| mft_dump | 283,262 |
| Velociraptor | 269,292 |

A ~20% spread. The tools make different choices about deleted and unallocated records, alternate data streams (which may appear as separate rows), and records they consider malformed.

**This does not affect any published result.** Every classification is keyed to a named case file, and all three parsers return that file's record with identical timestamp values. Total record count is a property of how a tool enumerates, not of what NTFS recorded.

It is documented here because the discrepancy looks alarming when first encountered and invites the wrong conclusion. Compare tools on the records they both resolve, not on how many rows they emit.

## Pinning

`tools/tool-hashes.json` records the SHA256 of every downloaded resource. A rerun verifies against the pin and **aborts on mismatch**. Results produced by a different parser build are not comparable to previously published ones. Re-pin deliberately with `Get-Tools.ps1 -Update`.
