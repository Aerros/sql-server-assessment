[README.md](https://github.com/user-attachments/files/31624899/README.md)
# SQL Server assessment queries

A first-pass assessment of a SQL Server instance you did not build, plus a lab
file for practising backup strategies safely.

Written for the situation where you inherit a server with thin documentation
and need to establish what is actually true before changing anything.

## Files

Run them in order. Each answers a different question.

### `01_server_and_database_config.sql` — what is this server?

| Query | Establishes |
|---|---|
| Version and edition | Which patch level, and whether features you might use are even licensed |
| `sys.databases` | Every database's state, recovery model, and what is blocking log reuse |
| `sys.master_files` | Where files live, how large, and how they grow |

The one to read carefully is the recovery model column. **FULL recovery with no
log backups means the transaction log grows until the disk fills.** You cannot
conclude that from this file alone — it tells you the recovery model, and file
02 tells you whether log backups exist. The finding is in the combination.

Also watch for data and log files on the same physical disk, and anything
sitting on C.

### `02_backup_history.sql` — are we actually backed up?

| Query | Establishes |
|---|---|
| Last backup per type | When each database was last backed up full, differential, and log |
| `restorehistory` | Whether anyone has ever restored anything on this instance |
| Backup detail per database | Where backups are physically landing, and how long they take |

The premise: **a backup job existing is not evidence. History is.** Jobs get
disabled, targets fill up, databases get added to a server and never added to
the job's database list.

Three things to look for:

- A database absent from the results entirely — never backed up, ever
- `last_log` NULL on a FULL recovery database — the file 01 time bomb, confirmed
- `restorehistory` returning nothing — nobody has proven the backups restore

That last one is usually empty, and the emptiness is the point. A backup that
has never been restored is a hypothesis.

### `03_health_and_access.sql` — is it intact and is anything failing?

| Query | Establishes |
|---|---|
| `DBCC DBINFO` | When CHECKDB last completed cleanly (`dbi_dbccLastKnownGood`) |
| `DBCC CHECKDB` | The corruption check itself — **commented out, expensive** |
| Job history | Which Agent jobs have been failing, and for how long |
| Job list | Which jobs exist, and whether they are enabled and scheduled |
| Server principals | Who has access, and through which roles |

`dbi_dbccLastKnownGood` showing 1900-01-01 means CHECKDB has never run cleanly.
Corruption that nobody checks for gets found by users instead, at which point
the good backups may already have aged out.

The job list matters separately from job history: a **disabled** backup job is a
very quiet way to have no backups, and it produces no failure history at all.

On access — anyone in `sysadmin` can issue `BACKUP` and write the file wherever
they like, including off-network. Backup files carry no security of their own;
anyone holding one can read everything in it.

### `99_lab_backup_practice` — practice environment

Numbered 99 because it sorts last and is not for real servers.

Gets a sample database into a state where full, differential, and log backups
can all be exercised. Covers the pseudo-simple trap: `ALTER DATABASE ... SET
RECOVERY FULL` does not start the log chain — the first full backup does, and
until then log backups fail.

Everything that writes is commented out.

## Safety

- **Files 01 and 02** are read-only and cheap. Safe to run whole.
- **File 03** is read-only, but `DBCC CHECKDB` can run for hours. It is
  commented out for that reason.
- **File 99** writes. Every write is commented out.
- `--!REPLACE` marks anything to change before running.
- In SSMS, **Ctrl+Shift+E** runs only the selected text. Worth making a habit
  before you ever open these against something that matters.

## What this does not cover

Performance, indexing, wait stats, high availability, and configuration review.
This answers "is the data safe and is anything broken," which is the first
question, not the only one.
