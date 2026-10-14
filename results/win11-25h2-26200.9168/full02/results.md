# NTFS Timestamp Rules - full02

**Build:** Microsoft Windows 11 Pro 25H2, build 26200.9168  
**ntfs.sys SHA256:** `24B023140A6D162DB3FE0D701109FC0BE4FDD9EC65E1C40522934AE3CC0A28C6`  
**Last access:** DisableLastAccess = 2  (System Managed, Last Access Time Updates ENABLED)  
**Tunneling:** DEFAULT (~15s, ENABLED)

Results apply to the `ntfs.sys` build above. See `docs/exceptions.md` for
conditions under which these rules do not hold.

---

## 1. Normal behaviour

**This is the primary result.** Files created and operated on conventionally,
with no prior timestamp manipulation. These tables describe what an analyst
sees on an ordinary system.

### `$STANDARD_INFORMATION`

| | Access | Modification | Rename | Copy | Local Move | Volume Move | Deletion |
|---|---|---|---|---|---|---|---|
| **Modified** | no change | op time | no change | inherited | no change | inherited | no change |
| **Access** | op time | op time | no change | **varies by mechanism** | no change | **varies by mechanism** | no change |
| **Metadata** | no change | op time | op time | inherited | op time | inherited | no change |
| **Creation** | no change | no change | no change | **varies by mechanism** | no change | **varies by mechanism** | no change |

**Where mechanism matters ($SI):**

| Operation | Timestamp | Mechanism | Result |
|---|---|---|---|
| Copy | Access | `cmd_copy` | op time |
| Copy | Access | `dotnet` | op time |
| Copy | Access | `powershell` | op time |
| Copy | Access | `robocopy` | inherited |
| Copy | Access | `robocopy_dat` | inherited |
| Copy | Access | `xcopy` | op time |
| Copy | Creation | `cmd_copy` | op time |
| Copy | Creation | `dotnet` | op time |
| Copy | Creation | `powershell` | op time |
| Copy | Creation | `robocopy` | inherited |
| Copy | Creation | `robocopy_dat` | inherited |
| Copy | Creation | `xcopy` | op time |
| Volume Move | Access | `cmd_move` | op time |
| Volume Move | Access | `dotnet` | op time |
| Volume Move | Access | `powershell` | op time |
| Volume Move | Access | `robocopy_move` | inherited |
| Volume Move | Creation | `cmd_move` | op time |
| Volume Move | Creation | `dotnet` | op time |
| Volume Move | Creation | `powershell` | op time |
| Volume Move | Creation | `robocopy_move` | inherited |

### `$FILE_NAME`

| | Access | Modification | Rename | Copy | Local Move | Volume Move | Deletion |
|---|---|---|---|---|---|---|---|
| **Modified** | no change | no change | indeterminate | op time | indeterminate | op time | no change |
| **Access** | no change | no change | indeterminate | op time | indeterminate | op time | no change |
| **Metadata** | no change | no change | indeterminate | op time | indeterminate | op time | no change |
| **Creation** | no change | no change | indeterminate | op time | indeterminate | op time | no change |

> **On "indeterminate" cells.** `$SI` and `$FN` hold identical values on a
> normally created file, so "unchanged" and "repopulated from `$SI`" produce
> the same observation. The *observed value* is correct and unambiguous; only
> the mechanism behind it cannot be read off a normal file. See section 3.

---

## 2. Behaviour after timestomping

A separate condition, not a correction to section 1. Here `$SI` was set to
distinct historical values **before** the operation, then the same operation
was performed. This shows how prior tampering changes what a later operation
leaves behind.

| Attr | Operation | Mechanism | Timestamp | Normal | After timestomping |
|---|---|---|---|---|---|
| `FN` | Local Move | `powershell` | Access | indeterminate | prev $SI acc |
| `FN` | Local Move | `dotnet` | Access | indeterminate | prev $SI acc |
| `FN` | Local Move | `cmd_move` | Access | indeterminate | prev $SI acc |
| `FN` | Local Move | `dotnet` | Creation | indeterminate | prev $SI create |
| `FN` | Local Move | `powershell` | Creation | indeterminate | prev $SI create |
| `FN` | Local Move | `cmd_move` | Creation | indeterminate | prev $SI create |
| `FN` | Local Move | `powershell` | Metadata | indeterminate | prev $SI meta |
| `FN` | Local Move | `dotnet` | Metadata | indeterminate | prev $SI meta |
| `FN` | Local Move | `cmd_move` | Metadata | indeterminate | prev $SI meta |
| `FN` | Local Move | `powershell` | Modified | indeterminate | prev $SI mod |
| `FN` | Local Move | `dotnet` | Modified | indeterminate | prev $SI mod |
| `FN` | Local Move | `cmd_move` | Modified | indeterminate | prev $SI mod |
| `FN` | Rename | `powershell` | Access | indeterminate | prev $SI acc |
| `FN` | Rename | `cmd_ren` | Access | indeterminate | prev $SI acc |
| `FN` | Rename | `dotnet` | Access | indeterminate | prev $SI acc |
| `FN` | Rename | `powershell` | Creation | indeterminate | prev $SI create |
| `FN` | Rename | `dotnet` | Creation | indeterminate | prev $SI create |
| `FN` | Rename | `cmd_ren` | Creation | indeterminate | prev $SI create |
| `FN` | Rename | `powershell` | Metadata | indeterminate | prev $SI meta |
| `FN` | Rename | `dotnet` | Metadata | indeterminate | prev $SI meta |
| `FN` | Rename | `cmd_ren` | Metadata | indeterminate | prev $SI meta |
| `FN` | Rename | `powershell` | Modified | indeterminate | prev $SI mod |
| `FN` | Rename | `dotnet` | Modified | indeterminate | prev $SI mod |
| `FN` | Rename | `cmd_ren` | Modified | indeterminate | prev $SI mod |

Differences here are mostly **resolution, not divergence**: a cell that reads
_indeterminate_ under normal conditions becomes decidable once `$SI` and `$FN`
have been forced apart. Where a value genuinely differs, it is called out below.

### Full timestomped tables

#### `SI` after timestomping

| | Access | Modification | Rename | Copy | Local Move | Volume Move | Deletion |
|---|---|---|---|---|---|---|---|
| **Modified** | no change | op time | no change | inherited | no change | inherited | no change |
| **Access** | op time | op time | no change | **varies by mechanism** | no change | **varies by mechanism** | no change |
| **Metadata** | no change | op time | op time | inherited | op time | inherited | no change |
| **Creation** | no change | no change | no change | **varies by mechanism** | no change | **varies by mechanism** | no change |

#### `FN` after timestomping

| | Access | Modification | Rename | Copy | Local Move | Volume Move | Deletion |
|---|---|---|---|---|---|---|---|
| **Modified** | no change | no change | prev $SI mod | op time | prev $SI mod | op time | no change |
| **Access** | no change | no change | prev $SI acc | op time | prev $SI acc | op time | no change |
| **Metadata** | no change | no change | prev $SI meta | op time | prev $SI meta | op time | no change |
| **Creation** | no change | no change | prev $SI create | op time | prev $SI create | op time | no change |

---

## 3. Mechanism notes

**These are laboratory inferences, not field observations.** Each describes how
NTFS populates a value internally, established only by forcing `$SI` and `$FN`
apart. On an ordinary file the analyst sees the section 1 value. Do not read
this section as a correction to section 1.

| Attr | Operation | Timestamp | Observed normally | Underlying mechanism |
|---|---|---|---|---|
| `FN` | Local Move | Access | indeterminate | prev $SI acc |
| `FN` | Local Move | Creation | indeterminate | prev $SI create |
| `FN` | Local Move | Metadata | indeterminate | prev $SI meta |
| `FN` | Local Move | Modified | indeterminate | prev $SI mod |
| `FN` | Rename | Access | indeterminate | prev $SI acc |
| `FN` | Rename | Creation | indeterminate | prev $SI create |
| `FN` | Rename | Metadata | indeterminate | prev $SI meta |
| `FN` | Rename | Modified | indeterminate | prev $SI mod |

---

## 4. Differences from the baseline charts

Compared against the published Windows 11 22H2 charts, using the **normal**
condition only.

| Attr | Operation | Mechanism | Timestamp | 22H2 chart | Observed |
|---|---|---|---|---|---|
| `SI` | Copy | `robocopy_dat` | Access | op time | inherited |
| `SI` | Copy | `robocopy` | Access | op time | inherited |
| `SI` | Copy | `robocopy` | Creation | op time | inherited |
| `SI` | Copy | `robocopy_dat` | Creation | op time | inherited |
| `SI` | Local Move | `dotnet` | Access | op time | no change |
| `SI` | Local Move | `cmd_move` | Access | op time | no change |
| `SI` | Local Move | `powershell` | Access | op time | no change |
| `SI` | Volume Move | `robocopy_move` | Access | op time | inherited |
| `SI` | Volume Move | `robocopy_move` | Creation | op time | inherited |
| `SI` | Volume Move | `cmd_move` | Metadata | op time | inherited |
| `SI` | Volume Move | `robocopy_move` | Metadata | op time | inherited |
| `SI` | Volume Move | `dotnet` | Metadata | op time | inherited |
| `SI` | Volume Move | `powershell` | Metadata | op time | inherited |
| `SI` | Rename | `powershell` | Access | op time | no change |
| `SI` | Rename | `cmd_ren` | Access | op time | no change |
| `SI` | Rename | `dotnet` | Access | op time | no change |

