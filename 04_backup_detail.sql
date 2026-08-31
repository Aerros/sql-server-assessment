/*
================================================================================
 BACKUP DETAIL - ONE DATABASE
================================================================================
 Question:   What is the actual backup history for this specific database,
             and where did each file get written?
 Safety:     Read-only. Select the WHOLE block - the DECLARE must run with it.
 Run when:   After the assessment query flags something and you need to see why,
             or when reconstructing a restore chain.
================================================================================
*/

DECLARE @db sysname = N'AdventureWorks2022';                    --!REPLACE

SELECT TOP (50)
    b.database_name,
    CASE b.type
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
        ELSE b.type
    END                                             AS backup_type,
    b.backup_start_date,
    b.backup_finish_date,
    DATEDIFF(SECOND, b.backup_start_date, b.backup_finish_date) AS seconds,
    b.backup_size / 1048576.0                       AS backup_size_mb,
    b.compressed_backup_size / 1048576.0            AS compressed_mb,
    b.server_name                                   AS taken_by_server,
    b.is_copy_only,
    b.has_backup_checksums,
    b.is_damaged,
    m.physical_device_name
FROM msdb.dbo.backupset AS b
JOIN msdb.dbo.backupmediafamily AS m
  ON m.media_set_id = b.media_set_id
WHERE b.database_name = @db
ORDER BY b.backup_finish_date DESC;
