# Explorer Test Procedure

Eleven cases must be performed by hand at the test system's desktop. Everything else in this study is automated; Explorer is not, because its operations need an interactive desktop session and both PowerShell Remoting and PowerShell Direct are non-interactive.

`harness\Invoke-ExplorerTest.ps1` handles staging, snapshots and capture. The operator does the clicking. It prompts before and after each action, so the measured window is nearly as tight as a scripted run, and it writes the same `run.json` the automated runner produces — `Compare-Results.ps1` consumes it unchanged.

**Time:** about 30 minutes.

---

## Why these cases matter

The published 22H2 charts contain one cell where the *mechanism* changes the answer: a cross-volume move sets `$SI` Creation to the time of the move via CLI, but **inherits it from the original** via Explorer. Case 07 is the half the automated runs cannot reach.

The remaining cases either confirm Explorer uses the same code path as the CLI equivalents, or cover operations with no CLI counterpart at all — browsing, opening in an application, and Recycle Bin deletion.

---

## Before you start

Work at the **guest console**, in an **elevated** PowerShell. Not over Remoting: the script refuses to run non-interactively, by design.

### Pre-flight

```powershell
cd C:\NtfsTest\repo
Set-ExecutionPolicy Bypass -Scope Process -Force

.\provision\Mount-TestVolumes.ps1 | Format-Table Name,Expected,Status,SizeGB,ShortNames -AutoSize
.\provision\Set-AmbientConfig.ps1 -Mode CleanRoom | Format-Table Item,Action,Detail -AutoSize

'--- confirm ---'
'Exclusions : ' + ((Get-MpPreference).ExclusionPath -join ', ')
'WSearch    : ' + (Get-Service WSearch).Status
'Elevated   : ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
```

All four must hold:

| Check | Required |
|---|---|
| `V:`, `W:`, `X:` | `attached`, `ShortNames ENABLED` |
| Exclusions | include `V:\`, `W:\`, `X:\` |
| `WSearch` | `Stopped` |
| Elevated | `True` |

> The exclusion step is not ceremonial. A `RealisticBaseline` run *removes* those exclusions, so if one was performed previously, skipping this leaves Defender scanning the test volumes.

### Why `V:` and `W:`, not `C:`

Windows Search updates `$SI` Access on files in indexed locations about a second after any change. `C:\Users\` is indexed; `V:`, `W:` and `X:` are not. Running these cases on an indexed path would make every Access result ambiguous between Explorer and the indexer.

### One Explorer setting

**Show file extensions**: View → Show → File name extensions. Case 03 renames a file and the extension must be visible.

---

## Running

```powershell
.\harness\Invoke-ExplorerTest.ps1 -RunLabel 'explorerNN'
```

Passing `-RunLabel` keeps the output directory predictable and matches the naming of the automated runs. Without it the label is a UTC timestamp.

The script stages eleven files, waits 20 seconds, takes the before snapshots, then walks through each case.

### For each case

1. It prints the **file path**, the **destination** (if any), and the **action**.
2. Open the folder(s) in Explorer and get ready — but do not act yet.
3. Press **Enter** to start the measured window.
4. Perform the action.
5. Press **Enter** immediately to close the window.
6. Answer where the file is now:
   - **Enter** — unchanged, or moved to the destination it named
   - **full path** — if renamed, or it ended up elsewhere
   - **`gone`** — permanently deleted

Explorer's **"Copy as path"** is the easiest way to answer step 6; the surrounding quotes are stripped automatically.

Type **`s`** at the first prompt to skip a case.

> **Keep the window tight.** Have the folders open and the file selected before pressing Enter. Dead time inside the window widens the comparison range.

---

## The cases

| # | Operation | Action | What it answers |
|---|---|---|---|
| 01 | Access | Single-click to select. **Do not open.** | Does browsing alone update Access? |
| 02 | Access | Double-click → opens Notepad → close | The commonest real "user accessed a file" |
| 03 | Rename | F2, rename to any new name | Does Explorer rename match the CLI? |
| 04 | Copy | Ctrl+C, Ctrl+V into destination (same volume) | Explorer copy baseline |
| 05 | Local move | Ctrl+X, Ctrl+V into destination (same volume) | Explorer move within a volume |
| 06 | Local move | **Drag** to destination (same volume = move) | Does drag differ from cut/paste? |
| 07 | **Volume move** | **Ctrl+X, Ctrl+V into the `W:` destination** | The CLI/Explorer divergence |
| 08 | Volume move | **Shift+drag** to `W:` destination | Shift forces a move. Matches cut/paste? |
| 09 | Copy | **Drag** to `W:` destination, no Shift | Cross-volume drag is a *copy*. Matches 04? |
| 10 | Delete | **Delete** → Recycle Bin | Recycle = move into `$Recycle.Bin` + rename to `$R…` |
| 11 | Delete | **Shift+Delete**, confirm | Should match the CLI delete rules |

### Notes on specific cases

**01 vs 02.** Keep these distinct — they separate "seen in a folder listing" from "opened".

**03.** Any new name works; record the exact name used. A name that fits 8.3 (for example `ren02.txt`) leaves the file with a single `$FILE_NAME` attribute instead of two, which is normal and does not change the timestamp result.

**06, 08, 09 — drag behavior.** Windows decides move-vs-copy from the volumes: same volume drag = **move**; different volume drag = **copy**; Shift forces **move**. Check the drag tooltip before releasing — it reads "Move to" or "Copy to". If it disagrees with the table, press Escape rather than proceeding.

**07.** Use Ctrl+X then Ctrl+V — not drag, which case 08 covers separately.

**10.** Leave the file in the Recycle Bin; **do not empty it**. The record is still live, renamed to `$R…`, and the script resolves it by MFT entry number. Answer **Enter** at the path prompt, not `gone`.

**11.** Answer **`gone`** at the path prompt.

---

## When finished

```powershell
.\harness\Compare-Results.ps1 -RunJson 'C:\NtfsTest\run\<RunLabel>\run.json'
```

The script prints the exact command with the real label. Outputs to review:

- `run.json`
- `summary-normal.csv`
- `access-vs-entrymodified.csv`
- `precision-analysis.csv`
- `pending-writes.csv` — only written if a value had not reached disk

A manual pass cannot be repeated cheaply. Ideally **run it twice** and compare the two passes cell-for-cell.

### What to record

The harness captures timestamps; it cannot capture what the operator saw. Operator should ideally keep notes such as the following:

1. Any prompt or dialog — UAC, "file in use", replace-or-skip, Defender.
2. Drag tooltips for cases 06, 08, 09 — did each read as the table expects?
3. Case 03 — the exact new filename.
4. Case 10 — the `$R…` name if visible.
5. Anything unexpected — a slow operation, a lingering progress bar, a
thumbnail regenerating. Explorer does background work and it can surface in the results.

---

## Expected results

Measured on Win11 25H2 build 26200.9168, identical across two passes. A reproduction should match this; a difference is either a change in Windows or a problem with the run.

### `$SI`

| Operation | Modified | Access | Metadata | Creation |
|---|---|---|---|---|
| Browse (01) | no change | no change | no change | no change |
| Open (02) | no change | op time | **op time** | no change |
| Rename (03) | no change | no change | op time | no change |
| Copy (04, 09) | inherited | op time | inherited | op time |
| Local move (05, 06) | no change | no change | op time | no change |
| **Volume move (07, 08)** | inherited | op time | **op time** | **inherited** |
| Recycle Bin (10) | no change | no change | **op time** | no change |
| Shift+Delete (11) | no change | no change | no change | no change |

`$FN` is unchanged for browse, open, recycle and shift-delete; operation time for copy and volume move; and indeterminate for rename and local move, where `$SI` and `$FN` hold the same values on an untampered file.

### The three results worth checking first

**Volume move Creation is `inherited`** — the CLI sets it to the move time. This confirms the 22H2 Explorer/CLI divergence still holds on 25H2, and it is the reason both columns remain on the published chart.

**Volume move Metadata is `op time`** — here the CLI is the outlier, inheriting it instead. So the two mechanisms differ on *two* cells, in opposite directions.

**Open updates Metadata; a programmatic read does not.** That is the application's behavior, not NTFS.

Everything else matches the CLI measurements, including Access remaining unchanged on rename and local move — confirming that change is mechanism-independent.
