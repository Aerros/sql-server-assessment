/*
================================================================================
 05 - HEALTH CHECKS
================================================================================
 Question:   Is the data intact, are the jobs succeeding, who has access, and
             are the backup files themselves actually readable?
 Safety:     All read-only. TWO exceptions are commented out because they are
             EXPENSIVE, not because they write:
               - DBCC CHECKDB       can run for hours on a large database
               - RESTORE VERIFYONLY reads an entire backup file end to end
 Run when:   First contact, then on a recurring basis.
 Conventions:
   --!REPLACE   set this before running
================================================================================
*/


/*
================================================================================
 CORRUPTION
================================================================================
*/

/*
 When did CHECKDB last complete cleanly on this database?

 EXPECT: one row, one column, a single datetime value.
   A recent date  = good, CHECKDB has run and passed.
   1900-01-01     = never run cleanly. This is a finding, not an error.

 Corruption nobody checks for gets found by users, by which point the good
 backups may already have aged out.

 Alternative if you want the full property dump instead of just this one
 value: DBCC DBINFO (N'AdventureWorks2022') WITH TABLERESULTS;
 Look for the row named dbi_dbccLastKnownGood in the results grid.
*/
SELECT
    DATABASEPROPERTYEX(
        'AdventureWorks2022',       --!REPLACE
        'LastGoodCheckDbTime'
    ) AS LastKnownGoodCheckDBDate;


/*
 CAUTION | The corruption check itself.
 Read-only, but hours of runtime and heavy I/O on a large database.
 Run off-hours, or against a restored copy on another server - which has the
 side benefit of testing the restore at the same time.

 EXPECT:
   CLEAN RESULT:  Just "Commands completed successfully." Nothing above it.
   BAD RESULT:    Error rows (e.g. "Msg 8909...") listed BEFORE that same
                  completion line. The command ALWAYS says "completed" -
                  that line alone does not mean the database is healthy.
                  Presence of error rows above it is the actual signal.
*/
DBCC CHECKDB (N'AdventureWorks2022') WITH NO_INFOMSGS, ALL_ERRORMSGS;  --!REPLACE


/*
================================================================================
 BACKUP FILE INSPECTION
 These read the backup FILE, not the history tables. 02_backup_history.sql
 tells you what SQL Server recorded; these tell you whether the file on disk
 is actually there and actually readable.
================================================================================
*/

/*
 CAUTION | Is this backup file present, complete, and internally consistent?
 Reads the whole file, so it takes roughly as long as a restore would.

 Catches: missing file, unreachable path, truncated file, checksum mismatch.
 Does NOT catch: a structurally valid backup of an already-corrupt database.
 CHECKSUM on the way out plus VERIFYONLY afterwards is the difference between
 a verified backup and a file that merely exists.
 Still not a restore test. Only a restore is a restore test.

 EXPECT: one line of text.
   "The backup set on file 1 is valid."      = good
   An error (e.g. file not found, checksum mismatch)  = bad, read the message
*/
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'  --!REPLACE
--     WITH CHECKSUM;


/*
 What is inside a .bak file?

 FILELISTONLY returns one row per file inside the backup (usually 2: data + log).
 ONLY LOOK AT THESE 2 COLUMNS, ignore the rest (~20 others):
   LogicalName    e.g. AdventureWorks2022, AdventureWorks2022_log
   PhysicalName   where the file lived on the machine that made the backup

 HEADERONLY returns one row describing the backup operation itself.
 ONLY LOOK AT THESE 3 COLUMNS, ignore the rest (~30 others):
   BackupType         1 = full, 2 = log
   BackupFinishDate   when the backup completed
   ServerName         machine that made it

 Run these before restoring a backup someone handed you, to confirm it is what
 they said it is. Cheap - they read the header, not the whole file.
*/
RESTORE FILELISTONLY
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE

RESTORE HEADERONLY
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE


/*
================================================================================
 SCHEDULED WORK
================================================================================
*/

/*
 Agent job outcomes, most recent first.
 run_status: 0 failed, 1 succeeded, 2 retry, 3 cancelled, 4 in progress.

 EXPECT: one row per job run. Read the "outcome" column.
   All "Succeeded"    = good
   Any "Failed"       = a finding - open that job's step history to see why
   No rows at all     = no jobs have ever run, or none are set up yet

 A job failing quietly for months is common. Absence of failure emails is not
 evidence of success - somebody has to actually be receiving them.
*/
SELECT TOP (50)
    j.name                          AS job_name,
    h.run_date,
    h.run_time,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
        WHEN 4 THEN 'In progress'
    END                             AS outcome,
    h.message
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs AS j
  ON j.job_id = h.job_id
WHERE h.step_id = 0                 /* 0 = the job overall, not one step */
ORDER BY h.run_date DESC, h.run_time DESC;


/*
 Which jobs exist at all, and are they enabled and scheduled?

 EXPECT: one row per job.
   job_enabled = 1 and schedule_enabled = 1   = normal, will run
   job_enabled = 0                            = a finding - silently disabled
   schedule_name is NULL                      = job has no schedule attached,
                                                 will never run on its own

 A DISABLED backup job is a very quiet way to have no backups - it produces
 no failure history, so the query above cannot see it.
*/
SELECT
    j.name                          AS job_name,
    j.enabled                       AS job_enabled,
    s.name                          AS schedule_name,
    s.enabled                       AS schedule_enabled,
    j.date_created,
    j.date_modified
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobschedules AS js
       ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS s
       ON s.schedule_id = js.schedule_id
ORDER BY j.name;


/*
================================================================================
 ACCESS
================================================================================
*/

/*
 Who has access at the server level, and through which roles?

 EXPECT: one row per login/user/group on the instance.
   server_role = 'sysadmin' is the one to scrutinize - that principal can do
   absolutely anything, including reading or moving backup files.
   is_disabled = 1 means that login currently cannot connect at all.

 Anyone in sysadmin can issue BACKUP and write the file anywhere they like,
 including off-network. Backup files carry no security of their own - whoever
 holds one can read everything in it.
*/
SELECT
    p.name                          AS principal_name,
    p.type_desc                     AS principal_type,
    p.is_disabled,
    r.name                          AS server_role
FROM sys.server_principals AS p
LEFT JOIN sys.server_role_members AS m
       ON m.member_principal_id = p.principal_id
LEFT JOIN sys.server_principals AS r
       ON r.principal_id = m.role_principal_id
WHERE p.type IN ('S', 'U', 'G')     /* SQL login, Windows user, Windows group */
ORDER BY p.name;
