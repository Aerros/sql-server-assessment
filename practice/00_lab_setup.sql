/*
================================================================================
 00 - LAB SETUP
================================================================================
 Question:   How do I get a practice database into a state where all three
             backup strategies can actually be exercised?
 Safety:     EVERYTHING HERE WRITES, and everything is commented out.
             Uncomment one block, check the --!REPLACE lines, run it, then
             re-comment it. WITH INIT means "overwrite whatever is at this
             path" - a stray F5 later should not be able to reach it.
 Run when:   Following along with training. Not on anything real.

 Numbered 00 so it sorts first: it is the setup step for everything else.
 Files 01-05 are read-only tools for real servers. This one is not.

 Scope note:
   Only commands that put a SAMPLE database into a teachable state live here.
   RESTORE VERIFYONLY, FILELISTONLY, and HEADERONLY are general-purpose
   read-only tools and live in 05_health_checks.sql.

 Prerequisites:
   - AdventureWorks2022 restored
   - C:\SQLBackups\AdventureWorks2022\FULL\ and \LOG\ created BY HAND.
     SQL Server does not create folders.
   - NT SERVICE\MSSQLSERVER granted Modify on C:\SQLBackups.
     Backups run as the SERVICE account, not as you. Skip this and you get
     "Operating system error 5 (Access is denied)."
================================================================================
*/


/*
 Switch to FULL recovery, then seed the log chain.

 ORDER MATTERS. The ALTER alone does NOT start the log chain. Until a full
 backup exists the database sits in "pseudo-simple": it reports FULL and
 behaves as SIMPLE, and log backups fail. The BACKUP below is what starts it.

 AdventureWorks restores in SIMPLE, so without this you cannot practise
 transaction log backups at all.

 On a real server this is a decision, not a step. FULL recovery commits you to
 scheduling log backups; skip them and the log grows until the disk fills.
*/
-- ALTER DATABASE AdventureWorks2022 SET RECOVERY FULL;                --!REPLACE
--
-- BACKUP DATABASE AdventureWorks2022                                  --!REPLACE
--     TO DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_seed.bak'  --!REPLACE
--     WITH INIT, CHECKSUM, COMPRESSION, STATS = 10;


/*
 Confirm it worked. Read-only, so left live.
 Run before and after the block above and compare:
   before -> SIMPLE
   after  -> FULL, and log_reuse_wait_desc moves to LOG_BACKUP once there is
             activity waiting to be backed up
*/
SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE name = N'AdventureWorks2022';                                    --!REPLACE


/*
 Take a transaction log backup.
 Errors if no full backup exists yet - that is the pseudo-simple behaviour
 above. Worth triggering deliberately once so you recognise the message.
*/
-- BACKUP LOG AdventureWorks2022                                       --!REPLACE
--     TO DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_log.trn'    --!REPLACE
--     WITH CHECKSUM, COMPRESSION, STATS = 10;


/*
 HOUSEKEEPING | Trim backup history in msdb.
 Deleting backup FILES does not touch this, and nothing trims it on its own.
 On a server running for years the first pass can take a long time and
 generate heavy log activity - work backwards in stages.

 Note: this is routine maintenance, NOT a fix for a slow query against
 backupset. That is an indexing problem - see 02_backup_history.sql.
*/
-- EXEC msdb.dbo.sp_delete_backuphistory
--     @oldest_date = '2025-01-01';                                    --!REPLACE
