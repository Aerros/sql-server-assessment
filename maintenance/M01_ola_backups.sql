/*
================================================================================
 OLA - THE CALLS I ACTUALLY USE
================================================================================
 Install from ola.hallengren.com. Do not vendor the script here - he updates it.
 Parameter reference: ola.hallengren.com/sql-server-backup.html

 Ola creates the jobs but NOT the schedules. Attaching schedules and failure
 alerts is on you, and is the step people skip.
================================================================================
*/

/* Full backup, all user databases. */
-- EXEC master.dbo.DatabaseBackup
--     @Databases     = N'USER_DATABASES',
--     @Directory     = N'C:\SQLBackups\Ola',        --!REPLACE
--     @BackupType    = N'FULL',
--     @Verify        = N'Y',    /* skip on very large or very many databases */
--     @Compress      = N'Y',
--     @CheckSum      = N'Y',
--     @CleanupTime   = 168;     --!REPLACE - hours. 168 = one week. Policy, not fact.
