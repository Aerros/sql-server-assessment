[README.md](https://github.com/user-attachments/files/31884076/README.md)
# sql-server-assessment

Queries for working out what is actually true about a SQL Server instance you
did not build, exercises for learning the mechanics by hand, and the automation
settings I use once I know what needs fixing.

Written for the situation where you inherit a server with thin documentation and
need evidence before you change anything.

## How the folders fit together

    assess/     what is broken
    lab/        what the fix does, by hand, on a database you can break
    maintain/   the fix, automated
    assess/     run it again and watch the flags clear

That last step is the point. If automation is set up correctly, the assessment
output changes. If it doesn't, something wasn't finished.

| Folder | Writes? | Safe on a real server? |
|---|---|---|
| `assess/` | No | Yes. Read-only throughout |
| `lab/` | Yes | **No.** Sample databases only |
| `maintain/` | Yes | Yes, once you have chosen the settings |
| `runbooks/` | what to do when something breaks, plus the drills that test each procedure |

## Conventions

| Marker | Meaning |
|---|---|
| `--!REPLACE` | A value to set before running — a database name, path, or threshold |
| `!OPT:` | In query output: this action depends on a decision the query cannot make |
| No prefix | In query output: this action is correct regardless of policy |

Thresholds are declared at the top of each file rather than buried in a `CASE`,
so the assumptions are visible.

**Flags vs descriptions.** A flag describes something that could be otherwise —
`stale_full` clears when the schedule is fixed. A column showing the same value
on every run regardless of anyone's action is a description, and lives with the
evidence columns rather than in `concern_count`. A flag that is always on trains
you to ignore the column it sits in.

---

# assess/

Read-only. Nothing here changes anything. Run in order on first contact with a
server.

### `01_instance_orientation.sql` — what is this server?

| Query | Establishes |
|---|---|
| Version and edition | Patch level, and whether features you might use are licensed |
| `sys.databases` | Each database's state, recovery model, and what blocks log reuse |
| `sys.master_files` | Where files live, how large, and how they grow |

Read the recovery model column against file 02. **Full recovery with no log
backups means the transaction log grows until the disk fills** — but this file
only tells you the recovery model. The finding lives in the combination.

Also watch for data and log files sharing a disk, percentage autogrowth, and
anything sitting on C.

### `02_backup_history.sql` — is there a usable backup?

The main query. One row per database, with evidence columns, twelve concern
flags, a `first_action`, and an `all_concerns` summary, sorted worst-first.

Beyond checking dates, it catches:

| Flag | Why it matters |
|---|---|
| `backup_to_nul` | The backup "succeeded" and the file went nowhere. In Full recovery it also truncated the log, silently breaking the chain |
| `never_backed_up` | No backup history on this instance at all |
| `pseudo_simple` | Full recovery but no full backup ever taken, so the log chain never started — reports FULL, behaves as SIMPLE, and point-in-time recovery does not exist |
| `foreign_backup` | The newest full was taken by a *different instance* — history that arrived with a restore, meaning no local backup exists |
| `damaged` | The backup completed but was flagged damaged |
| `full_recovery_no_log` | The log grows until the disk fills |
| `latest_full_copy_only` | `COPY_ONLY` cannot base a differential, so a full-plus-diff restore plan is broken |
| `no_checksum` | Corruption can be written into the backup with nothing noticing |
| `backup_on_data_drive` | One disk failure takes the database and its backups together |
| `stale_full` / `stale_log` | Older than the declared tolerance |
| `not_online` | Cannot be backed up in its current state |

`full_location_type` is a description, not a flag: `UNC` or `local`. UNC is the
preferred setup — backups on a different machine survive the server dying — but
it also means reachability depends on the service account's access to that
share, which no query can test. Use it to decide which paths deserve a
`RESTORE VERIFYONLY`.

**The premise: a backup job existing is not evidence. History is.** Jobs get
disabled, targets fill, databases get added to a server and never added to the
job's database list.

**Known limit.** This reports what SQL Server *recorded*, not what exists on
disk now. A path on a decommissioned file server looks identical to a live one.
Only `RESTORE VERIFYONLY` — or an actual restore — closes that gap.

**Performance.** `ROW_NUMBER` sorts within each database/type partition. Index
`backupset` to match and the sort disappears:

```sql
CREATE NONCLUSTERED INDEX IX_backupset_db_type_finish
    ON msdb.dbo.backupset (database_name, type, backup_finish_date DESC);
```

Trimming history with `sp_delete_backuphistory` is worthwhile housekeeping, but
it is not the fix for this query being slow.

### `03_restore_history.sql` — has a restore ever been proven?

Every restore performed on this instance, joined back to the backup it came
from, so each row is traceable rather than just a timestamp.

On most servers this returns nothing, and **the emptiness is the finding.** A
backup that has never been restored is a hypothesis.

Note: it records restores done *on this instance*. A restore performed elsewhere
from these files leaves no trace here.

### `04_backup_detail.sql` — drill down on one database

Full backup history for a single database, including device paths, duration,
sizes, and the copy-only / checksum / damaged flags.

**02 flags, 04 explains.** When the assessment query raises something, this is
where you find out why.

### `05_health_checks.sql` — is it intact, and is anything failing?

| Query | Establishes |
|---|---|
| `DBCC DBINFO` | When CHECKDB last completed cleanly (`dbi_dbccLastKnownGood`) |
| `DBCC CHECKDB` | The corruption check itself — **commented out, expensive** |
| `RESTORE VERIFYONLY` | Whether the backup file is present, complete, and checksum-clean — **commented out, reads the whole file** |
| `RESTORE FILELISTONLY` / `HEADERONLY` | What is inside a `.bak` — logical names, sizes, when and by whom it was taken |
| Job history | Which Agent jobs have been failing, and for how long |
| Job list | Which jobs exist, and whether they are enabled and scheduled |
| Server principals | Who has access, and through which roles |

**`02` reports what SQL Server recorded. The `RESTORE` commands here read the
actual file.** That is the gap between a backup that exists in history and one
that exists on disk.

`dbi_dbccLastKnownGood` showing 1900-01-01 means CHECKDB has never run cleanly.
Corruption nobody checks for gets found by users, by which point the good
backups may have aged out.

The job list matters separately from job history: a **disabled** backup job is a
very quiet way to have no backups, and it produces no failure history at all.

On access — anyone in `sysadmin` can issue `BACKUP` and write the file wherever
they like, including off-network. Backup files carry no security of their own.

---

# lab/

Exercises against a sample database. **Everything here writes. Not for real
servers.** Writes are commented out; uncomment one block at a time.

### `L00_lab_setup.sql` — get a database into a teachable state

Puts a sample database where full, differential, and log backups can all be
exercised.

Covers the pseudo-simple trap: `ALTER DATABASE ... SET RECOVERY FULL` does not
start the log chain. The first full backup does, and until then log backups fail
with an error that does not obviously say why.

Prerequisites are in the file header — folders created by hand, and Modify
rights granted to the SQL Server service account. Backups run as the *service*,
not as you.

### `L01_point_in_time.sql` — recover a deleted row with `STOPAT`

Recovers a row that was inserted and then deleted, by restoring to a moment
between the two. **Restores to a new database name — never over the original.**

Deliberately takes only **one** log backup, containing both the insert and the
delete, so `STOPAT` has to stop partway through a log rather than at its end.
Backing up the log between the two operations would let you stop at a file
boundary and skip the feature entirely.

Two things that bite: `NORECOVERY` on every restore except the last, and `MOVE`
is required because the original database still holds its files.

Includes a troubleshooting section — the first attempt usually fails, and the
errors are not self-explanatory.

The shape worth remembering, since the syntax you look up:

    1. Restore the full                   NORECOVERY
    2. Restore the differential, if any   NORECOVERY
    3. Restore each log in order          NORECOVERY
    4. The last one                       STOPAT + RECOVERY
    5. Always to a new name, with MOVE for each file

---

# maintain/

Calls to Ola Hallengren's maintenance solution — the settings I actually use.

**Ola's script is not in this repo, deliberately.** It is roughly 5,000 lines he
maintains and updates. Install from `ola.hallengren.com`; don't vendor a copy
that will drift. What lives here is the part that is mine: which parameters I
chose, and why.

The script itself documents almost nothing — the parameter reference is entirely
on the website:

- `ola.hallengren.com/sql-server-backup.html`
- `ola.hallengren.com/sql-server-integrity-check.html`
- `ola.hallengren.com/sql-server-index-and-statistics-maintenance.html`

### `M01_ola_backups.sql` — backup calls and retention

**The thing people miss: Ola creates the jobs but not the schedules.** They sit
there correctly configured and never run. Attaching schedules and failure alerts
is a separate step, and skipping it produces an instance that looks protected
and is not — which `02_backup_history.sql` would then flag as
`never_backed_up`.

`@CleanupTime` is in **hours**. 168 = one week. It is a policy decision, marked
`--!REPLACE`. SQL Server can only express "delete files older than N", so tiered
retention — weekly for six weeks, monthly for six months — is out of scope for
the tool and has to be solved elsewhere.

`@Verify` runs `RESTORE VERIFYONLY` after each backup. Good by default; skip it
on very large databases or very many of them, where it roughly doubles job
duration.

`@ChangeBackupType` takes a full backup when a diff or log backup cannot run —
usually because the database is new and has no full yet. Worth setting if
anything creates databases on the fly, otherwise those databases silently go
unprotected.

Ola builds its own folder tree beneath whatever root you give it:
`<directory>\<server>\<database>\<backup type>\`, with timestamped filenames.
Nothing is ever overwritten; retention is handled by the cleanup job deleting old
files rather than by `WITH INIT`.

---

## Safety

- `assess/` is read-only throughout. `DBCC CHECKDB` in 05 is read-only but can
  run for hours, so it is commented out, as is `RESTORE VERIFYONLY`.
- `lab/` writes. Every write is commented out. Sample databases only.
- `maintain/` writes, and sets up recurring work. Read the parameter reference
  before running anything here against a real server.
- In SSMS, **Ctrl+Shift+E** runs only the selected text. Worth making a habit
  before opening any of these against something that matters.

## What this does not cover

Performance tuning, indexing strategy, wait statistics, high availability, and
configuration review. This answers "is the data safe and is anything broken,"
which is the first question, not the only one.
