[README.md](https://github.com/user-attachments/files/31884954/README.md)
# runbooks/

Recovery procedures for a SQL Server instance, plus the drills that test them.

## The set

| File | What it is | Open it when |
|---|---|---|
| `RUNBOOK_00_recovery_planning.md` | RPO/RTO, tooling inventory, retention derivation, detection controls, contacts, rebuild inventory | Before anything else. Filled in while calm, reviewed on a schedule |
| `RUNBOOK_01_backup_strategy.md` | Designing and implementing backups from the RPO/RTO | Setting up a server that has no backups, or replacing ones you don't trust |
| `RUNBOOK_02_oops_query.md` | Point-in-time restore after someone ran the wrong statement | A person made a mistake and the database is otherwise healthy |
| `RUNBOOK_03_corruption.md` | Detection, scope, recovery decision tree, last resort | The data is wrong at the page level |
| `DRILL_backup_strategy.md` | Exercise for Runbook 01 | — |
| `DRILL_corruption.md` | Exercise for Runbook 03, with five variants | — |

The drill for Runbook 02 is `lab/L01_point_in_time.sql`.

## Which runbook, and which section

Every node names the section to open. You are not meant to read a runbook
front to back — land where the arrow points.

```mermaid
flowchart TD
    START([Something is wrong]) --> Q0{Is RUNBOOK_00<br/>filled in?}

    Q0 -- No, and no incident yet --> R00[RUNBOOK_00<br/>Fill sections 1–2 first]
    Q0 -- No, but incident is live --> LIVE[Discover live:<br/>RUNBOOK_03 §2.1 queries]
    Q0 -- Yes --> Q1{What happened?}
    LIVE --> Q1

    Q1 -- A person ran<br/>the wrong statement --> R02[RUNBOOK_02<br/>Oops Query]
    Q1 -- Query error 823/824/825<br/>backup failed on CHECKSUM<br/>CHECKDB reported errors<br/>data looks wrong, cause unknown --> R03[RUNBOOK_03<br/>Corruption]
    Q1 -- No backups exist<br/>or I don't trust them --> R01[RUNBOOK_01<br/>Backup Strategy]
    Q1 -- Server / storage / site<br/>is gone --> DR[Not written yet<br/>Start from RUNBOOK_00 §6<br/>rebuild inventory]

    %% ---------- Oops Query ----------
    R02 --> O1[§1 Log backup NOW<br/>Stop deletion jobs]
    O1 --> O2[§2 Establish WHEN]
    O2 --> O3{§3 Does the chain<br/>reach past the mistake?}
    O3 -- No: SIMPLE recovery<br/>or gap in logs --> O3N[Tell requester:<br/>last full is all there is]
    O3 -- Yes --> O4[§4 Restore to NEW name<br/>STOPAT before the mistake]
    O4 --> O5{Landed correctly?}
    O5 -- Overshot --> O5N[DROP the copy<br/>retry with earlier STOPAT]
    O5N --> O4
    O5 -- Yes --> O6[§5 Hand back<br/>with a deadline]
    O6 --> O7[§6 Re-enable jobs<br/>Delete copy on deadline<br/>Record time-to-recover]

    %% ---------- Corruption ----------
    R03 --> C1[§2.1 Stop ANYTHING<br/>that deletes backups]
    C1 --> C2[§2.2 Scope:<br/>suspect_pages]
    C2 --> C3[§3 Tell app owner<br/>and storage team]
    C3 --> C4[§4.1 When did CHECKDB<br/>last pass cleanly?]
    C4 --> C5[§4.2 Full CHECKDB<br/>save the output]
    C5 --> C6{§4.3 What is damaged?}

    C6 -- Nonclustered<br/>index only --> F1[§5.1 Drop and<br/>recreate the index]
    C6 -- Table, allocation page,<br/>or system table --> F2{Does a backup<br/>reach past the last<br/>clean CHECKDB?}
    C6 -- master, model,<br/>or msdb --> F3[Rebuild the instance<br/>RUNBOOK_00 §6]

    F2 -- Yes --> F2Y[§5.2 Restore that full<br/>+ every log since<br/>to a NEW name]
    F2 -- No --> F2N[§5.3 Last resort<br/>Read the whole section first<br/>Four preconditions]

    F1 --> V[CHECKDB on the result<br/>Clean?]
    F2Y --> V
    F2N --> V
    V -- No --> C6
    V -- Yes --> C7[§5.4 Re-enable everything<br/>disabled in §2.1]
    C7 --> C8[§6 Root cause<br/>Known gaps<br/>Drill log]
```

Three loops are drawn deliberately: oops-query overshoot (retry with an earlier
`STOPAT`), corruption re-check (CHECKDB again after any fix), and the fact that
both runbooks return to a re-enable step before closing out. Those loops are
the trial-and-error the prose describes in paragraphs, here as arrows.

**Not on this chart:** high availability and disaster recovery. Both need
infrastructure this server may not have. `RUNBOOK_00_recovery_planning.md`
section 6 is the starting inventory for a DR runbook, not yet written.

## Reading order

**00 first.** Every other runbook references it. If its section 1 — the RPO/RTO
grid — is empty, the others are guesswork.

Then whichever runbook matches the situation. They are written to stand alone
once 00 exists.

## How the drills work

Each drill is one scenario, start to finish, on a sample database. Every step
asks you to **predict before you run.** Being wrong is the point — a prediction
you got wrong is remembered; an instruction you followed is not.

The drills produce the runbooks' drill logs. A runbook nobody has followed end
to end against a deliberately broken database is untested, and says so on the
page.

## Conventions

| Marker | Meaning |
|---|---|
| `--!REPLACE` | Set before running |
| `!OPT:` | Depends on a decision the document cannot make |
| `<!-- -->` | A prompt to answer, invisible in preview. Search for `<!--` before calling a runbook finished |

## What this set does not cover

**High availability** and **disaster recovery** — the other two columns of the
RPO/RTO grid. Both need infrastructure this server may not have (availability
groups, log shipping, a second site). Runbook 00 section 6 is the start of a DR
runbook: the inventory of what would have to be rebuilt by hand.

## Why runbooks rather than memory

Brent Ozar reads the documentation every time he does a restore, and he has
been doing this for decades. The commands are not meant to be remembered. What
professionals have instead is a written procedure, produced while calm, tested
against a broken database, and kept next to the thing it describes.
