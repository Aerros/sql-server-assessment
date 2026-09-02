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
 Look for the row: dbi_dbccLastKnownGood
 A date of 1900-01-01 means it has never run cleanly - which is the finding.
 Corruption nobody checks for gets found by users, by which point the good
 backups may already have aged out.
*/
DBCC DBINFO (N'AdventureWorks2022') WITH TABLERESULTS;              --!REPLACE


/*
 CAUTION | The corruption check itself.
 Read-only, but hours of runtime and heavy I/O on a large database.
 Run off-hours, or against a restored copy on another server - which has the
 side benefit of testing the restore at the same time.
*/
-- DBCC CHECKDB (N'AdventureWorks2022') WITH NO_INFOMSGS, ALL_ERRORMSGS;  --!REPLACE


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
*/
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'  --!REPLACE
--     WITH CHECKSUM;


/*
 What is inside a .bak file?
 FILELISTONLY  - logical file names and sizes, so you can plan MOVE clauses
 HEADERONLY    - when it was taken, by which server, type, size, whether
                 COPY_ONLY, whether compressed

 Run these before restoring a backup someone handed you, to confirm it is what
 they said it is. Cheap - they read the header, not the whole file.
*/
-- RESTORE FILELISTONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE
--
-- RESTORE HEADERONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE


/*
================================================================================
 SCHEDULED WORK
================================================================================
*/

/*
 Agent job outcomes, most recent first.
 run_status: 0 failed, 1 succeeded, 2 retry, 3 cancelled, 4 in progress.
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
