# Explorer Test Procedure

Eleven cases are performed in Explorer at the test system's desktop: by hand, following this plan, and additionally by an automated driver (see [Automated pass](#automated-pass)). The manual passes are the reference; the automated pass is an extra test that must reproduce them. Explorer operations need an interactive desktop session, and both PowerShell Remoting and PowerShell Direct are non-interactive, so these cases sit outside the main automated runs.

`harness\Invoke-ExplorerTest.ps1` handles staging, snapshots and capture. In a manual pass the operator does the clicking, and the script prompts before and after each action to bracket the measured window. It writes the same `run.json` the automated runner produces — `Compare-Results.ps1` consumes it unchanged.

**Time:** about 30 minutes.

---

## Why these cases matter

The published 22H2 charts contain one cell where the *mechanism* changes the answer: a cross-volume move sets `$SI` Creation to the time of the move via CLI, but **inherits it from the original** via Explorer. Case 07 is the half the automated runs cannot reach.

The remaining cases either confirm Explorer uses the same code path as the CLI equivalents, or cover operations with no CLI counterpart at all — browsing, opening in an application, and Recycle Bin deletion.

---

## Before you start

Work at the **guest console**, in an **elevated** PowerShell. Not over Remoting: a manual pass refuses to run non-interactively, by design.

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

A manual pass cannot be repeated cheaply. Ideally **run it twice** and compare the two passes cell-for-cell:

```powershell
.\harness\Compare-Runs.ps1 -RunDir C:\NtfsTest\run\explorer01, C:\NtfsTest\run\explorer02
```

### What to record

The harness captures timestamps; it cannot capture what the operator saw. Operator should ideally keep notes such as the following:

1. Any prompt or dialog — UAC, "file in use", replace-or-skip, Defender.
2. Drag tooltips for cases 06, 08, 09 — did each read as the table expects?
3. Case 03 — the exact new filename.
4. Case 10 — the `$R…` name if visible.
5. Anything unexpected — a slow operation, a lingering progress bar, a
thumbnail regenerating. Explorer does background work and it can surface in the results.

---

## Automated pass

An additional pass performs the same eleven cases with an automated driver instead of an operator. It does not replace the manual passes. It is compared against them, and the two should agree cell for cell; a disagreement is investigated, not averaged away.

### How it works

It runs from the host over PowerShell Remoting. `Invoke-ExplorerTest.ps1 -Driver Automated` stages and snapshots exactly as a manual pass does, then hands the operations to `harness\Invoke-ExplorerDriver.ps1`, started in the logged-on user's desktop session through a scheduled task with an interactive token. Remoting has no desktop, and a scheduled task is the way to reach one from it.

The driver follows one rule: automation sets the stage, and the operation itself is real input. It opens and arranges the folder windows through the Shell COM interface and locates the file with UI Automation, which is the preparation an operator does before pressing Enter. Everything inside the measured window is a mouse click, a drag or a keystroke sent through `SendInput`, so Explorer runs the same code path it runs for a person. Performing the operations through Shell COM verbs (`CopyHere`, `MoveHere`) would be testing a different mechanism.

Every step checks that it happened: the window opened, the file was drawn on screen, the point about to be clicked belongs to the expected window and file, the window had focus before a keystroke, and the file ended up where the case says. The drag cases check whether the file was moved or copied, which is the equivalent of reading the drag tooltip. A step that cannot be verified fails the case, which is then excluded from classification, and the driver saves a screenshot of the desktop for diagnosis.

### Prerequisites

The pre-flight above applies, run over Remoting. In addition:

| Requirement | Why |
|---|---|
| The harness user is logged on at the console, desktop unlocked | The driver acts on that desktop. Disable the lock-screen timeout for the run. |
| Nobody uses the console during the run | The driver is using the mouse and keyboard. |
| File name extensions shown | Case 03, as for a manual pass. |

The driver runs elevated. Windows silently discards injected input while a higher-integrity window has focus, and an elevated console is often left open on a test VM. The operations are unaffected: they are performed by the user's own unelevated `explorer.exe`, and Notepad, launched by Explorer for case 02, inherits that.

### Running

```powershell
.\harness\Invoke-ExplorerTest.ps1 -Driver Automated -RunLabel 'explorerautoNN'
```

The driver's progress is relayed to the Remoting session. Its log, manifest, results and any failure screenshots are kept in the run's `automation\` folder, and each case in `run.json` records the steps the driver took.

Classify the run as usual, then line it up against the manual passes:

```powershell
.\harness\Compare-Runs.ps1 -RunDir C:\NtfsTest\run\explorer01, C:\NtfsTest\run\explorer02, C:\NtfsTest\run\explorerautoNN
```

### Measured windows differ

An operator's measured window is wide: 7 to 86 seconds across the two 25H2 manual passes. The driver's measured 0.1 to 3.1 seconds: under a second for a single click or keystroke, one to one and a half seconds for rename and copy or cut and paste, and about 3 seconds for a drag or for opening and closing Notepad. A write that lands a few seconds after an operation falls inside the first and possibly outside the second, so `Compare-Runs.ps1` lists window widths alongside any disagreement.

On 25H2 the first automated pass (`explorerauto01`) agreed with both manual passes on all 88 cells.

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

**Open updates Metadata; a programmatic read does not.** That is the shell giving the file an object ID for its Recent Items shortcut, not NTFS, so it happens only when the file has none yet. The staged files never do; opening one a second time changes Access alone. Explorer also adds object IDs on rename and moves; see `findings.md` §7.

Everything else matches the CLI measurements, including Access remaining unchanged on rename and local move — confirming that change is mechanism-independent.
