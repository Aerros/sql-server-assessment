/*
================================================================================
 RESTORE HISTORY
================================================================================
 Question:   Has anyone ever proven these backups are restorable?
 Safety:     Read-only and cheap. Safe to run whole.
 Run when:   First contact with a server, alongside the backup evidence query.

 On most servers this returns nothing, and the emptiness IS the finding.
 A backup that has never been restored is a hypothesis, not a safeguard.

 Note: this records restores performed ON this instance. A restore done
 elsewhere from these backup files leaves no trace here.
================================================================================
*/

SELECT TOP (50)
    r.destination_database_name,
    r.restore_date,
    r.user_name,
    CASE r.restore_type
        WHEN 'D' THEN 'Database'
        WHEN 'F' THEN 'File'
        WHEN 'G' THEN 'Filegroup'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
        WHEN 'V' THEN 'Verifyonly'
        ELSE r.restore_type
    END                             AS restore_type,
    b.backup_finish_date            AS source_backup_taken,
    b.server_name                   AS source_backup_server
FROM msdb.dbo.restorehistory AS r
LEFT JOIN msdb.dbo.backupset AS b
       ON b.backup_set_id = r.backup_set_id
ORDER BY r.restore_date DESC;
