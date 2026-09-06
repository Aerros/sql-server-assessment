# Runbook 03 — Corruption

**Applies to:** <!-- server / instance -->
**Owner:** <!-- -->
**Last reviewed:** <!-- -->
**Last drill:** <!-- DRILL_corruption.md is the drill for this runbook -->

**Scenario:** the data is wrong at the page level and nobody knows since when.
Storage wrote garbage, a driver intercepted a write, or a SQL Server bug wrote
bad data with a valid checksum.

**Requires:** Runbook 00 filled in — particularly sections 2 (tooling), 3
(retention), and 5 (contacts). This runbook assumes nothing about what is
installed; every step discovers rather than assumes.

---

## 1. How you find out

Corruption is discovered one of four ways. The response is the same; the
starting point differs.

| Discovery | What it looks like | What it tells you |
|---|---|---|
| **A query fails** | Msg 824 "logical consistency-based I/O error", 823, or 825 | One page is bad. Scope unknown |
| **A backup fails** | `BACKUP` with `CHECKSUM` errors on a page | Same — and only if CHECKSUM was on |
| **CHECKDB reports errors** | Job fails; output file has hundreds of lines | Full scope, if the whole database was checked |
| **A user reports odd behaviour** | Application errors, missing rows, wrong values | Could be anything. Treat as corruption until ruled out |

<!--
SQL Server does not alert on any of these by default. Discovery usually means
a person noticed. The gap between corruption happening and discovery is the
thing that determines whether recovery is possible — which is why Runbook 00
section 4 exists.
-->

---

## 2. First five minutes

### 2.1 Stop anything deleting backups

You may suddenly need backups older than normal retention. Every minute this
is not done, backups you might need are being deleted.

**If Runbook 00 section 2 is filled in, act on it and skip to 2.2.** Otherwise:

```sql
/* Every job and its state */
SELECT job_id, name, enabled FROM msdb.dbo.sysjobs ORDER BY name;
```

```sql
/* Which job steps delete things? Covers Ola, maintenance plans, and
   hand-rolled cleanup in T-SQL, CmdExec, or PowerShell. */
SELECT j.name AS job_name, j.enabled, s.step_id, s.step_name, s.command
FROM msdb.dbo.sysjobsteps AS s
JOIN msdb.dbo.sysjobs     AS j ON j.job_id = s.job_id
WHERE s.command LIKE '%CleanupTime%'              /* Ola */
   OR s.command LIKE '%xp_delete_file%'           /* maintenance plans */
   OR s.command LIKE '%sp_delete_backuphistory%'
   OR s.command LIKE '%sp_purge_jobhistory%'
   OR s.command LIKE '%forfiles%'
   OR s.command LIKE '%Remove-Item%'
   OR s.command LIKE '%del %'
   OR j.name    LIKE '%cleanup%'
   OR j.name    LIKE '%purge%'
   OR j.name    LIKE '%delete%'
ORDER BY j.name, s.step_id;
```

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'<name>', @enabled = 0;   --!REPLACE, one per job
```

<!--
Record every job disabled, HERE, as you go. Section 5.4 re-enables them and
nothing else will remind you.

Disabled at <time>:
  -
  -

NOT in sysjobs, and must also be stopped:
  - Third-party backup product retention (its own console)
  - Storage lifecycle policies, tape rotation, cloud expiry (call the owner)
  - Windows Task Scheduler cleanup scripts
-->

### 2.2 Scope

```sql
SELECT * FROM msdb.dbo.suspect_pages;
```

| Result | Meaning |
|---|---|
| One database, few pages | Contained. Possibly an easy fix |
| One database, many pages | That database needs restoring |
| Multiple databases | Storage or instance-level. Nobody limps along; the server is on fire |
| Empty | **Not clean.** This table populates only when a page is *read*. Run CHECKDB |

*Optional, if installed:* `EXEC sp_Blitz @CheckServerInfo = 1;` — priority 1–50
is what matters.

---

## 3. Tell people

Before diagnosis, not after. The reason is that every write from now on may be
unrecoverable, and that is the application owner's decision to make.

| Who | Say | Template |
|---|---|---|
| **Application owner** | Corruption found. Writes from this point may not survive recovery. Do you want to stop the application? | brentozar.com/go/corruption |
| **Storage team** | Heads-up, not blame. Are you seeing anything on your side? | Same page |
| **Management** | Once section 2.2 has told you the scope | — |

---

## 4. Diagnose

### 4.1 Has this been going on for a while?

```sql
/* CHECKDB and backup job history */
SELECT TOP (100) j.name, h.run_date, h.run_time,
       CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded'
            WHEN 2 THEN 'Retry' WHEN 3 THEN 'Cancelled' WHEN 4 THEN 'In progress' END AS outcome,
       h.message
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs       AS j ON j.job_id = h.job_id
WHERE h.step_id = 0
ORDER BY h.run_date DESC, h.run_time DESC;
```

```sql
/* When did CHECKDB last pass? dbi_dbccLastKnownGood. 1900-01-01 = never */
DBCC DBINFO (N'<db>') WITH TABLERESULTS;                            --!REPLACE
```

Also run `assess/02_backup_history.sql` and `assess/05_health_checks.sql`.

<!--
A CHECKDB job that has been failing for months, emailing someone who left, is
common. The date of the last CLEAN check is the most important fact in this
runbook - it decides which backup you restore from.
-->

### 4.2 Full check

```sql
DBCC CHECKDB (N'<db>') WITH NO_INFOMSGS, ALL_ERRORMSGS, EXTENDED_LOGICAL_CHECKS;  --!REPLACE
```

Save the complete output. It is what Microsoft or a specialist will ask for.

<!--
NO_INFOMSGS        drops the "no errors found" lines so the errors are visible
ALL_ERRORMSGS      does not truncate after 200 errors
EXTENDED_LOGICAL_CHECKS  catches bug-written corruption that checksums miss

On a very large database this runs for hours. Run it on a restored copy on
another server if production cannot afford it.
-->

### 4.3 Read the output — what is actually damaged?

The last lines say `CHECKDB found N allocation errors and M consistency errors`
and suggest a minimum repair level. **Do not act on the suggestion yet.** Read
what is damaged first:

| Damaged object | Recovery option | Data loss |
|---|---|---|
| **Nonclustered index only** | Drop and recreate the index | **None.** The data is in the clustered index |
| **Clustered index / heap** (the table itself) | Restore from backup | None, if the chain reaches past the corruption |
| **Allocation pages** (PFS, GAM, SGAM) | Restore. Do not attempt repair | Same |
| **System tables** in the database | Restore, or rebuild the database | Same |
| **`master`, `model`, or `msdb`** | **Do not restore.** Rebuild the instance | Whatever the rebuild inventory in Runbook 00 section 6 does not cover |
| **Page-level, FULL recovery, Enterprise edition** | `RESTORE ... PAGE = 'file:page'` from a clean backup | None |

<!--
Index ID in the error message tells you which:
  index_id 0   heap (the table)
  index_id 1   clustered index (the table)
  index_id 2+  nonclustered index (recreatable)

Object ID → name:
  SELECT OBJECT_NAME(<object_id>) ;
  SELECT name FROM sys.indexes WHERE object_id = <id> AND index_id = <index_id>;

A corrupt system database means the instance cannot be trusted. Restoring
master requires single-user mode and it is rare enough that nobody does it
well. Rebuild.
-->

---

## 5. Recover

### 5.1 If it is a nonclustered index

```sql
/* Script the index definition out of SSMS first, then: */
DROP INDEX <index> ON <schema>.<table>;                             --!REPLACE
CREATE INDEX ...;  /* from the scripted definition */
DBCC CHECKDB (N'<db>') WITH NO_INFOMSGS;
```

Clean CHECKDB afterward is the confirmation. Skip to 5.4.

### 5.2 If it needs a restore

**Which backup:** not the newest. If a SQL Server bug wrote the corruption,
checksums did not catch it, and every backup since the **last clean CHECKDB**
is suspect. Restore the last full taken before that, plus every log since.

```sql
/* Backups that exist, and where */
SELECT b.backup_finish_date, b.type, b.server_name, b.has_backup_checksums,
       m.physical_device_name
FROM msdb.dbo.backupset         AS b
JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
WHERE b.database_name = N'<db>'                                     --!REPLACE
ORDER BY b.backup_finish_date DESC;
```

```sql
RESTORE VERIFYONLY FROM DISK = N'<path>' WITH CHECKSUM;             --!REPLACE each file you plan to use
```

**Always to a new name.** The corrupt copy is evidence and you may need more
than one attempt.

```sql
RESTORE FILELISTONLY FROM DISK = N'<full path>';                    --!REPLACE

RESTORE DATABASE <db>_Recovered                                     --!REPLACE
    FROM DISK = N'<full path>'
    WITH MOVE '<logical data>' TO N'<new>.mdf',                     --!REPLACE
         MOVE '<logical log>'  TO N'<new>.ldf',                     --!REPLACE
         NORECOVERY, STATS = 10;

RESTORE LOG <db>_Recovered FROM DISK = N'<log 1>' WITH NORECOVERY;  --!REPLACE
/* ... every log in order ... */
RESTORE LOG <db>_Recovered FROM DISK = N'<log N>' WITH RECOVERY;    --!REPLACE
```

*Optional:* `sp_DatabaseRestore` from the First Responder Kit builds this from
a folder. Two minutes to install; worth it past a dozen logs.

**Prove it:**

```sql
DBCC CHECKDB (N'<db>_Recovered') WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;
```

A restore that completes is not a recovery. A clean CHECKDB on the restored
copy is.

Then cut over: rename corrupt → `<db>_TO_BE_DELETED`, rename recovered → original
name. Give the old copy a deletion date.

### 5.3 The last resort — read this whole section before running anything

`REPAIR_ALLOW_DATA_LOSS` does exactly what it says. It deallocates whatever it
cannot fix. Rows disappear. Referential integrity is not preserved. You will
not get a list of what was lost.

Use it **only** when:

- No backup reaches past the corruption, **and**
- You have confirmed that with the backup history and with VERIFYONLY, **and**
- The application owner has agreed in writing that some data loss beats no
  database, **and**
- You have taken a full backup of the corrupt database first, so the repair can
  be undone by restoring it

```sql
/* Full backup of the corrupt state first. This is your undo. */
BACKUP DATABASE <db> TO DISK = N'<path>\<db>_PRE_REPAIR.bak' WITH INIT;  --!REPLACE

ALTER DATABASE <db> SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DBCC CHECKDB (N'<db>', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS, ALL_ERRORMSGS;
ALTER DATABASE <db> SET MULTI_USER;

DBCC CHECKDB (N'<db>') WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;  /* clean? */
```

<!--
If you are reaching for this, the earlier runbooks failed. Note that in
section 6.1 so it does not happen again.

Fork the work first (Brent's step 7): one person on restore attempts, one on
a Microsoft case, one calling a specialist from brentozar.com/go/corruption.
Repair is what you do while those are exhausted, not instead of them.
-->

### 5.4 Re-enable what you disabled in 2.1

**Do not skip this.** The list is in the comment block under 2.1.

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'<name>', @enabled = 1;   --!REPLACE
SELECT name, enabled FROM msdb.dbo.sysjobs ORDER BY enabled, name;  /* anything still off? */
```

Also anything paused outside SQL Server.

---

## 6. Afterwards

### 6.1 Root cause and what changed

| Date | Cause, as far as known | Change made | Why |
|---|---|---|---|
| | | | |

<!--
Common causes, from the Corruption module: storage hardware, drivers between
SQL Server and disk (anti-virus, replication, defrag), cloud I/O bandwidth
starvation, SQL Server bugs fixed by cumulative updates.

"We don't know" is an honest root cause and worth writing down as such.
-->

### 6.2 Known gaps

<!--
Starting points:
- SQL Server does not alert on corruption by default
- Backups without CHECKSUM succeed on corrupt data
- Restores do not check for corruption either
- suspect_pages populates only when a page is read
- VSS snapshot backups cannot detect page-level corruption at all
- Retention outside SQL Server is owned by people not on the contact list
- CHECKDB had not run cleanly in <N> days at the time of discovery
-->

### 6.3 Drill log

| Date | Who | What broke in the procedure | Fixed? |
|---|---|---|---|
| | | | |

---

## References

| | |
|---|---|
| Drill for this runbook | `DRILL_corruption.md` |
| Brent's corruption checklist, template emails, specialist list | brentozar.com/go/corruption |
| Corruption alert setup | brentozar.com/go/alert |
| First Responder Kit — `sp_Blitz`, `sp_DatabaseRestore` | brentozar.com/first-aid |
| `DBCC CHECKDB` syntax and repair options | `DBCC CHECKDB site:learn.microsoft.com` |
| `RESTORE` syntax, including page restore | Highlight in SSMS, F1 |
| Corruption module notes | Fundamentals of Database Administration, Corruption 1 |
