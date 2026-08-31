[README.md](https://github.com/user-attachments/files/31658519/README.md)
# sql-server-assessment

Read-only queries for working out what is actually true about a SQL Server
instance you did not build, plus a lab file for practising backup strategies.

Written for the situation where you inherit a server with thin documentation
and need evidence before you change anything.

## Conventions

| Marker | Meaning |
|---|---|
| `--!REPLACE` | A value to set before running — usually a database name, path, or threshold |
| `!OPT:` | In query output: this action depends on a decision the query cannot make |
| No prefix | In query output: this action is correct regardless of policy |

Thresholds are declared at the top of each file rather than buried in a `CASE`,
so the assumptions are visible.

## Root
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

The main query. One row per database, with evidence columns, eleven concern
flags, a `first_action`, and an `all_concerns` summary, sorted worst-first.

Beyond checking dates, it catches:

| Flag | Why it matters |
|---|---|
| `backup_to_nul` | The backup "succeeded" and the file went nowhere. In Full recovery it also truncated the log, silently breaking the chain |
| `foreign_backup` | The newest full was taken by a *different instance* — history that arrived with a restore, meaning no local backup exists |
| `never_backed_up` | No backup history on this instance at all |
| `pseudo_simple` | Full recovery but no full backup ever taken, so the log chain never started — reports FULL, behaves as SIMPLE, and point-in-time recovery does not exist |
| `damaged` | The backup completed but was flagged damaged |
| `latest_full_copy_only` | `COPY_ONLY` cannot base a differential, so a full-plus-diff restore plan is broken |
| `no_checksum` | Corruption can be written into the backup with nothing noticing |
| `backup_on_data_drive` | One disk failure takes the database and its backups together |
| `full_recovery_no_log` | The log grows until the disk fills |
| `stale_full` / `stale_log` | Older than the declared tolerance |
| `not_online` | Cannot be backed up in its current state |

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

Note: it records restores done *on this instance*. A restore performed
elsewhere from these files leaves no trace here.

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

`02_backup_history.sql` reports what SQL Server recorded. 
The RESTORE commands here read the actual file, which is what closes the gap between 
a backup that exists in history and one that exists on disk.

`dbi_dbccLastKnownGood` showing 1900-01-01 means CHECKDB has never run cleanly.
Corruption nobody checks for gets found by users, by which point the good
backups may have aged out.

The job list matters separately from job history: a **disabled** backup job is a
very quiet way to have no backups, and it produces no failure history at all.

On access — anyone in `sysadmin` can issue `BACKUP` and write the file wherever
they like, including off-network. Backup files carry no security of their own.

## Safety

- Files **01–05** are read-only. `DBCC CHECKDB` in 05 is read-only but can run
  for hours, so it is commented out.
- File **00** writes. Every write is commented out.
- In SSMS, **Ctrl+Shift+E** runs only the selected text. Worth making a habit
  before opening any of these against something that matters.

## What this does not cover

Performance, indexing, wait statistics, high availability, and configuration
review. This answers "is the data safe and is anything broken," which is the
first question, not the only one.

## Practice Folder 
~~~
This folder holds exercises against a sample database. Everything here writes. Not for real servers.
~~~

### `L00_lab_setup.sql` — practice environment 1

Gets a sample database into a state where full, differential, and log backups
can all be exercised. **Everything that writes is commented out.**

Covers the pseudo-simple trap: `ALTER DATABASE ... SET RECOVERY FULL` does not
start the log chain. The first full backup does, and until then log backups
fail with an error that does not obviously say why.

Prerequisites are listed in the file header — folders created by hand, and
Modify rights granted to the SQL Server service account.


### `L01_point_in_time.sql` — practice environment 2

Recovers a row that was inserted and then deleted, by restoring to a moment
between the two. **Restores to a new database name — never over the original.**

Deliberately takes only **one** log backup, containing both the insert and the
delete, so `STOPAT` has to stop partway through a log rather than at its end.
Backing up the log between the two operations would let you stop at a file
boundary and skip the feature entirely.

Two things that bite: `NORECOVERY` on every restore except the last, and `MOVE`
is required because the original database still holds its files.
