/*
================================================================================
 02 - BACKUP EVIDENCE
================================================================================
 Question:   Are we actually backed up, and has a restore ever been tested?
 Safety:     Read-only and cheap. The last block needs a DECLARE, so select it
             rather than running the file blind.
 Run when:   First contact, and any time someone says "we have backups."

 The point of this file: a backup JOB existing is not evidence. History is.
================================================================================
*/


/*
 Last backup of each type, per database.
 Read this against file 01:
   - FULL recovery with a NULL last_log  -> the log will grow until the disk fills
   - Database a database with NULL in all three date columns/last two -> never backed up local, ever
   - last_full older than your tolerance -> the schedule is not doing what
     someone thinks it is
*/
SELECT
    d.name                                          AS database_name,
    d.recovery_model_desc,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full,
    MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS last_differential,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
       ON b.database_name = d.name
WHERE d.name <> 'tempdb'                    /* tempdb is never backed up */
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;


/*
 Restore history.
 On most servers this returns nothing, and the emptiness IS the finding:
 nobody has ever proven the backups are restorable.
*/
SELECT TOP (50)
    destination_database_name,
    restore_date,
    user_name,
    restore_type
FROM msdb.dbo.restorehistory
ORDER BY restore_date DESC;


/*
 Backup detail for ONE database, including where each file was written.
 Use to reconstruct a restore chain, to find where backups are actually
 landing, or to prove a specific backup ran.
 Select this whole block and run it - the DECLARE needs to execute with it.
*/
-- DECLARE @db sysname = N'AdventureWorks2022';                     --!REPLACE
--
-- SELECT TOP (50)
--     b.database_name,
--     CASE b.type
--         WHEN 'D' THEN 'Full'
--         WHEN 'I' THEN 'Differential'
--         WHEN 'L' THEN 'Log'
--         ELSE b.type
--     END                                             AS backup_type,
--     b.backup_start_date,
--     b.backup_finish_date,
--     DATEDIFF(SECOND, b.backup_start_date, b.backup_finish_date) AS seconds,
--     b.backup_size / 1048576.0                       AS backup_size_mb,
--     b.compressed_backup_size / 1048576.0            AS compressed_mb,
--     m.physical_device_name
-- FROM msdb.dbo.backupset AS b
-- JOIN msdb.dbo.backupmediafamily AS m
--   ON m.media_set_id = b.media_set_id
-- WHERE b.database_name = @db
-- ORDER BY b.backup_finish_date DESC;
