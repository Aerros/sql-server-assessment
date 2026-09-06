# Runbook 02 — Oops Query

**Applies to:** <!-- server / instance -->
**Owner:** <!-- -->
**Last reviewed:** <!-- -->
**Last drill:** <!-- lab/L01_point_in_time.sql is the drill for this runbook -->

**Scenario:** a person ran the wrong statement. DELETE without a WHERE, UPDATE
against the wrong table, DROP TABLE, a bad deployment script. The database is
healthy; the data is wrong.

**Requires:** Runbook 00 filled in. This runbook is fast if the database is in
FULL recovery with log backups running, and mostly impossible if it isn't.

---

## 1. First five minutes

### 1.1 Stop the bleeding

Ask the requester: **is the application still writing?** Every change after the
mistake is data you might have to reconcile by hand later. They decide whether
to stop it — you tell them what it costs not to.

### 1.2 Take a log backup now

```sql
BACKUP LOG <db>                                                   --!REPLACE
    TO DISK = N'<path>\<db>_LOG_oops_<yyyymmdd_hhmmss>.trn'       --!REPLACE
    WITH CHECKSUM, COMPRESSION;
```

<!--
This captures everything up to this moment, including the mistake and whatever
happened after. You need it in the chain to restore to any point after the
last scheduled log backup. It costs seconds and it cannot hurt.
-->

### 1.3 Stop anything that deletes backups

Same discovery queries as Runbook 03 section 2.1. Less urgent than for
corruption — you need recent backups, not old ones — but a cleanup job firing
mid-restore is still a bad afternoon.

---

## 2. Establish what happened

Get these from the requester. Write the answers down before touching anything.

| Question | Answer |
|---|---|
| Which database | <!-- --> |
| Which table(s) | <!-- --> |
| What statement, as exactly as they can recall | <!-- --> |
| **When** — as precisely as possible | <!-- --> |
| Was anything written to the same tables *after* the mistake that must be kept | <!-- --> |
| Do they need the whole database back, or specific rows/objects | <!-- --> |

<!--
"When" is the whole restore. Get it from:
  - the requester's memory (usually ±5 minutes)
  - application logs with timestamps
  - the table's own modified-date columns, if it has them
  - msdb.dbo.backupset — everything in the last log backup happened before its
    backup_finish_date, which bounds the window

Aim STOPAT before the mistake, not at it. A second of margin costs nothing and
prevents replaying the statement you are trying to escape.
-->

---

## 3. Confirm the chain exists

```sql
SELECT b.backup_finish_date, b.type, b.server_name, m.physical_device_name
FROM msdb.dbo.backupset         AS b
JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
WHERE b.database_name = N'<db>'                                   --!REPLACE
  AND b.backup_finish_date >= DATEADD(DAY, -2, GETDATE())
ORDER BY b.backup_finish_date;
```

You need: the most recent **full** before the mistake, the most recent
**differential** after that full if any, and **every log** from then to past
the mistake, with no gaps.

<!--
A gap ends the chain at the gap. If a log backup is missing from the middle,
you can recover to just before the gap and no further.

If the database is in SIMPLE recovery there are no log backups. You can
restore the last full and that is all. Tell the requester now, before they
expect more.
-->

Confirm the files are actually there:

```sql
RESTORE VERIFYONLY FROM DISK = N'<path>' WITH CHECKSUM;           --!REPLACE
```

---

## 4. Restore to a new name

**Never over the original.** Two reasons: the requester will discover they also
needed something they told you to discard, and aiming STOPAT is trial and error
— being wrong should cost another attempt, not production.

### 4.1 Find the logical file names

```sql
RESTORE FILELISTONLY FROM DISK = N'<full backup path>';            --!REPLACE
```

### 4.2 The chain

```sql
RESTORE DATABASE <db>_oops                                        --!REPLACE
    FROM DISK = N'<full backup path>'                              --!REPLACE
    WITH MOVE '<logical data name>' TO N'<new path>\<db>_oops.mdf',      --!REPLACE
         MOVE '<logical log name>'  TO N'<new path>\<db>_oops_log.ldf',  --!REPLACE
         NORECOVERY, STATS = 10;
GO

/* Differential, only if one exists after the full: */
-- RESTORE DATABASE <db>_oops FROM DISK = N'<diff path>' WITH NORECOVERY;

/* Every log in order, all NORECOVERY except the last: */
RESTORE LOG <db>_oops FROM DISK = N'<log 1>' WITH NORECOVERY;     --!REPLACE
RESTORE LOG <db>_oops FROM DISK = N'<log 2>' WITH NORECOVERY;     --!REPLACE

/* The one containing the mistake: stop just before it. */
RESTORE LOG <db>_oops FROM DISK = N'<log N>'                      --!REPLACE
    WITH STOPAT = '<yyyy-mm-dd hh:mm:ss>',                        --!REPLACE seconds, not fractions
         RECOVERY;
GO
```

<!--
NORECOVERY on every restore except the last. RECOVERY ends the chain - say it
early and you start over from the full.

STOPAT takes datetime. '2026-09-06 14:23:45' works. Seven decimal places from
SYSDATETIME() does not.

MOVE is required because the original database still holds its file paths.
Left side is the logical name from FILELISTONLY; right side is any path.

Many logs? sp_DatabaseRestore from the First Responder Kit builds the chain
from a folder. Two minutes to install, worth it past a dozen files.
-->

### 4.3 Check the landing

```sql
SELECT TOP (100) * FROM <db>_oops.dbo.<table> ORDER BY <key> DESC;   --!REPLACE
```

Is the data as it was just before the mistake? If you overshot, `DROP DATABASE
<db>_oops` and repeat from 4.2 with an earlier STOPAT. You cannot rewind a
restore — each attempt starts from the full.

---

## 5. Hand it back

The requester usually knows their own data better than you do.

| Situation | What you do |
|---|---|
| **Specific rows or objects** needed | Give them `<db>_oops` and a **deadline**. They pull what they need across. You delete the copy when the deadline passes |
| **Whole database** needed, nothing written since | Rename original → `<db>_TO_BE_DELETED`. Rename `<db>_oops` → original name. Both stay online briefly |
| **Whole database** needed, but writes happened since | Same rename, then the *requester* reconciles the post-mistake writes from `_TO_BE_DELETED`. Not your data to merge |
| Database has replication, log shipping, mirroring, or an AG | **Stop.** Restoring breaks all of these differently. Read the documentation for the specific feature before proceeding |

```sql
/* Rename, both stay online */
ALTER DATABASE <db>      MODIFY NAME = <db>_TO_BE_DELETED;         --!REPLACE
ALTER DATABASE <db>_oops MODIFY NAME = <db>;                       --!REPLACE
```

<!--
The deadline matters. Without one, the copy lives for years and gets backed up
and CHECKDB'd every night. State it in writing: "deleted on <date>."
-->

---

## 6. Afterwards

### 6.1 Re-enable what you disabled in 1.3

### 6.2 Delete the copy on the deadline

```sql
DROP DATABASE <db>_TO_BE_DELETED;                                  --!REPLACE
```

### 6.3 Record it

| Date | What was run | By whom | Restored to | Time to recover |
|---|---|---|---|---|
| | | | | |

<!--
"Time to recover" against the RTO in Runbook 00 is the honest measure of
whether this runbook works. If it took four hours and the RTO is two, that is
a finding.
-->

### 6.4 Known gaps

<!--
Starting points:
- SIMPLE recovery databases cannot be restored to a point in time at all
- Object-level restore does not exist natively; it is restore-the-whole-thing
  and extract. Third-party tools do this in one step
- Multi-database applications restore to slightly different points in time
  because backups run serially. STOPAT to the weakest link, or marked
  transactions in the application
- A requester's "when" is usually wrong by minutes
-->

---

## References

| | |
|---|---|
| Drill for this runbook | `lab/L01_point_in_time.sql` |
| `RESTORE` syntax | Highlight in SSMS, F1. Or `RESTORE transact-sql site:learn.microsoft.com` |
| Chain builder | `sp_DatabaseRestore`, brentozar.com/first-aid |
| Restores module notes | Fundamentals of Database Administration, Backups 2 |
