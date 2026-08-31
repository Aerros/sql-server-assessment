/*
================================================================================
 99 - LAB SETUP
================================================================================
 Question:   How do I get a practice database into a state where all three
             backup strategies can actually be exercised?
 Safety:     EVERYTHING THAT WRITES IS COMMENTED OUT. Uncomment one block at a
             time, check the --!REPLACE lines, then run it.
 Run when:   Following along with training. Not on anything real.

 Numbered 99 so it sorts last. Files 01-03 are for real servers; this one is
 for a sample database you are willing to break.

 Prerequisites:
   - AdventureWorks2022 restored
   - C:\SQLBackups\AdventureWorks2022\FULL\ and \LOG\ created BY HAND
     (SQL Server will not create folders for you)
   - NT SERVICE\MSSQLSERVER granted Modify on C:\SQLBackups
     (backups run as the service account, not as you - "Operating system
     error 5 (Access is denied)" is what you get if you skip this)
================================================================================
*/


/*
 Switch to FULL recovery, then seed the log chain.

 ORDER MATTERS. The ALTER alone does NOT start the log chain. Until a full
 backup exists, the database sits in "pseudo-simple": it reports FULL and
 behaves as SIMPLE, and log backups fail. The full backup below is what
 actually starts it.

 AdventureWorks restores in SIMPLE by default, so without this you cannot
 practice transaction log backups at all.
*/
-- ALTER DATABASE AdventureWorks2022 SET RECOVERY FULL;                --!REPLACE
--
-- BACKUP DATABASE AdventureWorks2022                                  --!REPLACE
--     TO DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'  --!REPLACE
--     WITH INIT, CHECKSUM, COMPRESSION, STATS = 10;


/*
 Confirm it worked. Run before and after the block above and compare.
 recovery_model_desc should now read FULL, and log_reuse_wait_desc should
 move to LOG_BACKUP once there is activity to back up.
*/
SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE name = N'AdventureWorks2022';                                    --!REPLACE


/*
 Take a transaction log backup.
 Errors if no full backup exists yet - which is the pseudo-simple behaviour
 described above, and worth triggering deliberately once so you recognise
 the error message.
*/
-- BACKUP LOG AdventureWorks2022                                       --!REPLACE
--     TO DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_log.trn'    --!REPLACE
--     WITH CHECKSUM, COMPRESSION, STATS = 10;


/*
 Verify a backup file is readable, without restoring it.
 CHECKSUM on the way out plus VERIFYONLY afterwards is the difference between
 a verified backup and a file that merely exists.
 Still not a restore test - only a restore is a restore test.
*/
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'  --!REPLACE
--     WITH CHECKSUM;


/*
 What is inside a .bak file? Logical file names, sizes, and header detail.
 Run these before restoring a backup you did not create, so you can plan
 MOVE clauses and confirm the file is what you think it is.
*/
-- RESTORE FILELISTONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE
--
-- RESTORE HEADERONLY
--     FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'; --!REPLACE


/*
 HOUSEKEEPING | Trim backup history in msdb.
 Deleting backup FILES does not touch this, and it grows forever. On a server
 that has been running for years the first run can take a long time and
 generate heavy log activity - work backwards in stages rather than deleting
 a decade in one statement.
*/
-- EXEC msdb.dbo.sp_delete_backuphistory
--     @oldest_date = '2025-01-01';                                    --!REPLACE
