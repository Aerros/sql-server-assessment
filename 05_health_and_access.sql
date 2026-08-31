/*
================================================================================
 03 - HEALTH CHECKS
================================================================================
 Question:   Is the data intact, are the jobs succeeding, and who has access?
 Safety:     Mostly read-only and cheap. ONE exception is commented out -
             DBCC CHECKDB is read-only but can run for hours. Do not F5 blind
             until you have read the note on that block.
 Run when:   First contact, then on a recurring basis.
================================================================================
*/


/*
 When did CHECKDB last complete cleanly on this database?
 Look for the row: dbi_dbccLastKnownGood
 A date of 1900-01-01 means it has never run cleanly - which is the finding.
 Corruption that nobody checks for is found by users, which is too late.
*/
DBCC DBINFO (N'AdventureWorks2022') WITH TABLERESULTS;              --!REPLACE


/*
 CAUTION | The corruption check itself.
 Read-only, but expensive: hours of runtime and heavy I/O on a large database.
 Run off-hours, or against a restored copy on another server - which has the
 side benefit of testing your restores at the same time.
*/
-- DBCC CHECKDB (N'AdventureWorks2022') WITH NO_INFOMSGS, ALL_ERRORMSGS;  --!REPLACE


/*
 Agent job outcomes, most recent first.
 run_status: 0 failed, 1 succeeded, 2 retry, 3 cancelled, 4 in progress.
 A job that has been failing quietly for months is common. Absence of failure
 emails is not evidence of success - somebody has to be receiving them.
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
 A disabled backup job is a very quiet way to have no backups.
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
 Who has access at the server level, and through which roles?
 Anyone in sysadmin can issue BACKUP and write the file anywhere, including
 off-network. Backups carry no security of their own.
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
