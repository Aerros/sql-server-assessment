# Drill — Corruption, end to end

One scenario, about an hour. You cause corruption, discover it the way you
would in real life, and recover from it.

The output is a recovery runbook. That is the point — you will not remember
these commands, and you are not supposed to. Professionals keep a written
procedure. This drill writes yours.

**Before each step, predict what will happen.** Two columns in a scratch file:
what I expected, what happened.

## Setup

Download **XVI32** — a free hex editor, no installation required.

Create somewhere disposable: `C:\SQLBackups\Drill\`

---

## Part 1 — A healthy database

```sql
CREATE DATABASE Drill;
GO
ALTER DATABASE Drill SET RECOVERY FULL;
GO
USE Drill;
GO
CREATE TABLE dbo.Songs (id int IDENTITY PRIMARY KEY, lyric nvarchar(200));
INSERT INTO dbo.Songs (lyric) VALUES
    (N'Slip out the back Jack'),
    (N'Make a new plan Stan'),
    (N'Hop on the bus Gus'),
    (N'Drop off the key Lee');
GO
SELECT * FROM dbo.Songs;
```

**1.1 — The baseline full backup.** This is the one you will recover from.

```sql
BACKUP DATABASE Drill
    TO DISK = N'C:\SQLBackups\Drill\Drill_CLEAN.bak'
    WITH INIT, CHECKSUM, COMPRESSION;
```

**1.2 — Prove it is clean.** Note the time this completes.

```sql
DBCC CHECKDB (Drill) WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;
```

No output means no errors. **That timestamp is the most important fact in this
drill** — it is the last moment you know the database was good.

**1.3 — Some activity afterwards**, so there is something to replay.

```sql
INSERT INTO dbo.Songs (lyric) VALUES (N'No need to be coy Roy');
GO
BACKUP LOG Drill TO DISK = N'C:\SQLBackups\Drill\Drill_log1.trn' WITH CHECKSUM;
GO
INSERT INTO dbo.Songs (lyric) VALUES (N'Just listen to me');
GO
BACKUP LOG Drill TO DISK = N'C:\SQLBackups\Drill\Drill_log2.trn' WITH CHECKSUM;
```

You now have six rows, one clean full, and two logs.

---

## Part 2 — Cause corruption

**2.1** Find the file:

```sql
SELECT physical_name FROM sys.master_files WHERE DB_NAME(database_id) = 'Drill';
```

**2.2** Take it offline so SQL Server releases the file:

```sql
USE master;
GO
ALTER DATABASE Drill SET OFFLINE;
```

**2.3** Open XVI32 **as administrator**. Open `Drill.mdf`. Search for `Stan`.

*Predict: will you be able to read it?*

Change `Stan` to `Flan`. Save. Close.

**2.4** Bring it back:

```sql
ALTER DATABASE Drill SET ONLINE;
```

*Predict: does this succeed? Does Object Explorer show anything unusual?*

---

## Part 3 — Discover it the way you actually would

**3.1** *Predict: does SQL Server know yet?*

```sql
SELECT * FROM msdb.dbo.suspect_pages;
```

**3.2** Now read the page:

```sql
USE Drill;
SELECT * FROM dbo.Songs;
```

**3.3** Check `suspect_pages` again. *What changed, and why only now?*

**3.4** **The one that matters.** Back it up with no checksum, then with:

```sql
BACKUP DATABASE Drill TO DISK = N'C:\SQLBackups\Drill\Drill_nocheck.bak' WITH INIT;
GO
BACKUP DATABASE Drill TO DISK = N'C:\SQLBackups\Drill\Drill_check.bak' WITH INIT, CHECKSUM;
```

*Predict each. One succeeds and produces a corrupt backup. Which, and what does
that mean for a shop that omits `CHECKSUM`?*

**3.5** Run your own `02_backup_history.sql`. *Does it notice anything? Should
it?*

**3.6** The real check:

```sql
DBCC CHECKDB (Drill) WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;
```

Read the output. It is not written for humans in a hurry — that is the point of
step 6 in Brent's checklist, "look for an easy fix."

---

## Part 4 — Recover

**4.1** Before anything else: *which backup do you restore from, and why not the
most recent one?*

Write the answer down before scrolling. It is the whole lesson of the module.

**4.2** Restore to a new name, so the corrupt database stays put:

```sql
USE master;
GO
RESTORE DATABASE Drill_Recovered
    FROM DISK = N'C:\SQLBackups\Drill\Drill_CLEAN.bak'
    WITH MOVE 'Drill'     TO N'C:\SQLData\Drill_Recovered.mdf',      --!REPLACE
         MOVE 'Drill_log' TO N'C:\SQLData\Drill_Recovered_log.ldf',  --!REPLACE
         NORECOVERY;
GO
RESTORE LOG Drill_Recovered
    FROM DISK = N'C:\SQLBackups\Drill\Drill_log1.trn' WITH NORECOVERY;
GO
RESTORE LOG Drill_Recovered
    FROM DISK = N'C:\SQLBackups\Drill\Drill_log2.trn' WITH RECOVERY;
```

Run `RESTORE FILELISTONLY` first if the logical names differ.

**4.3** Prove it worked:

```sql
SELECT * FROM Drill_Recovered.dbo.Songs;
DBCC CHECKDB (Drill_Recovered) WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;
```

Six rows, `Stan` intact, CHECKDB clean.

**4.4** *You recovered from a full backup taken before the last clean CHECKDB,
plus every log since. What would have happened if your log retention had been
shorter than the gap between CHECKDB runs?*

That question is the retention rule, arrived at rather than told.

---

## Part 5 — Write the runbook

Fill in `RUNBOOK_TEMPLATE.md`, titled "Corruption response."

You now have the material, because you just did it:

- **Section 6, failure modes** — the error text from 3.2, the failed backup from
  3.4, the CHECKDB output from 3.6. Real messages someone can search for
- **Section 7, recovery** — the exact commands from Part 4, with the reasoning
  for choosing the older backup
- **Section 8, known gaps** — SQL Server does not alert on corruption by
  default. Backups without `CHECKSUM` succeed on corrupt data. `suspect_pages`
  populates only when something reads the page

Add Brent's seven-step checklist near the top, since the first step — **turn off
backup deletion jobs** — is time-critical and easy to forget under pressure.

**This runbook is the answer to "I will not remember the queries."** You are not
supposed to. You are supposed to have written them down while calm.

---

## Cleanup

```sql
USE master;
GO
DROP DATABASE Drill;
DROP DATABASE Drill_Recovered;
```

Delete `C:\SQLBackups\Drill\`.

---

## Questions to be able to answer afterwards

1. Why did the backup succeed on a corrupt database?
2. Why did `suspect_pages` stay empty until you ran a `SELECT`?
3. Why restore the older full rather than the newest one?
4. What does `EXTENDED_LOGICAL_CHECKS` catch that `PHYSICAL_ONLY` misses, and
   why does that matter for SQL Server bugs specifically?
5. If CHECKDB runs weekly, what is the minimum log retention, and why is the
   minimum not the right answer?

---

# VARIANTS

Once the base drill works, repeat it with these changes. Each teaches a
different branch of `RUNBOOK_03_corruption.md` section 4.3.

## Variant A — corrupt a nonclustered index, not the data

Before Part 2, add an index:

```sql
CREATE NONCLUSTERED INDEX IX_lyric ON dbo.Songs (lyric);
```

In the hex editor, search for `Stan` — you will now find it **twice**. One
copy is the table (clustered index), one is `IX_lyric`. Corrupt only the
second occurrence.

*Predict:* does `SELECT * FROM dbo.Songs` fail? What about
`SELECT lyric FROM dbo.Songs WHERE lyric LIKE 'M%'`? Why the difference?

Run CHECKDB. Read the `index_id` in the error. Then:

```sql
DROP INDEX IX_lyric ON dbo.Songs;
CREATE NONCLUSTERED INDEX IX_lyric ON dbo.Songs (lyric);
DBCC CHECKDB (Drill) WITH NO_INFOMSGS;
```

No restore. No data loss. **This is the "easy fix" branch**, and knowing to
check for it before restoring is the whole point of reading CHECKDB output
rather than reacting to it.

## Variant B — discovered by a failing backup, not a query

Skip Part 3.2 (the SELECT). Go straight to the backup with CHECKSUM.

*Predict:* is `suspect_pages` populated? By what?

This is how corruption is usually found in a shop with checksums on and no
monitoring: the nightly backup fails and someone reads the email. Notice how
much less information you have than after a query failure.

## Variant C — the backup you would have chosen is also corrupt

After corrupting in Part 2, take **another** full backup with no checksum and
name it `Drill_LATEST.bak`. Then in Part 4.1, ask which backup to restore from.

*Predict:* if you restore from `Drill_LATEST.bak`, what does CHECKDB say on the
restored copy?

Do it. Watch it fail. Then restore from `Drill_CLEAN.bak` instead.

This is the retention rule made visible: **the newest backup is not the right
one**, and the right one only exists if retention reaches past the last clean
CHECKDB.

## Variant D — CHECKDB has never run

Before Part 1.2, skip the CHECKDB entirely. Corrupt, discover, and then try to
answer Part 4.1.

*You cannot.* Without a last-known-good, you do not know which backup to trust.
Every backup is suspect and the only honest recovery is "restore the oldest one
you still have and hope."

That is what `dbi_dbccLastKnownGood = 1900-01-01` means on an inherited server,
and why it is a finding in `05_health_checks.sql`.

## Variant E — the last resort

Delete every `.bak` and `.trn` in the Drill folder after corrupting. No backup
exists.

Now work through `RUNBOOK_03_corruption.md` section 5.3. Take the pre-repair
backup, run `REPAIR_ALLOW_DATA_LOSS`, read what it did.

*Predict:* how many rows survive? Which ones? Can you tell from the output what
was lost?

The answer to that last question is "no," and it is why the section says
"read this whole section before running anything."
