/*
================================================================================
 L01 - POINT IN TIME RECOVERY (STOPAT)
================================================================================
 Goal:    Recover a row that was inserted and then deleted, by restoring to a
          moment between the two.

 Safety:  Writes. Runs against AdventureWorks2022 and restores to a NEW
          database name. The original is never touched. Run one step at a
          time. Do not F5 the whole file.

 Written for someone who has only ever backed up and restored through the
 SSMS GUI. Every clause is explained the first time it appears, and there is
 a TROUBLESHOOTING section at the bottom for when a step fails - because the
 first attempt usually does.

 Prerequisites:
   - AdventureWorks2022 in FULL recovery with a full backup already taken
   - C:\SQLBackups\AdventureWorks2022\FULL\ and \LOG\ exist
   - Somewhere to put the restored copy's files. This script uses
     C:\SQLData\ - create it, or change the paths in STEP 7.
================================================================================
*/


/*==============================================================================
 STEP 1 - Create something to lose
==============================================================================*/

USE AdventureWorks2022;
GO

CREATE TABLE dbo.PITR_Demo (
    id          int IDENTITY(1,1) PRIMARY KEY,
    note        nvarchar(100),
    created_at  datetime DEFAULT GETDATE()
);
GO


/*==============================================================================
 STEP 2 - Baseline full backup

 Clauses used here:
   INIT         overwrite this backup FILE if it already exists. Safe on a
                full backup. NEVER use it on a log backup file - it would
                discard earlier logs and break the chain.
   CHECKSUM     verify pages while reading and write a checksum over the
                backup, so corruption cannot be copied in silently.
   COMPRESSION  smaller file, less to write.

 Taking a new full backup does NOT break or reset the log chain.
==============================================================================*/

BACKUP DATABASE AdventureWorks2022
    TO DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak'
    WITH INIT, CHECKSUM, COMPRESSION;
GO


/*==============================================================================
 STEP 3 - Insert the row you are going to lose
==============================================================================*/

INSERT INTO dbo.PITR_Demo (note) VALUES (N'This row must survive');
GO

SELECT * FROM dbo.PITR_Demo;        /* confirm it is there */
GO


/*==============================================================================
 STEP 4 - Record the safe point, then wait

 GETDATE() returns datetime, which is what STOPAT accepts.
 Do NOT use SYSDATETIME() - it returns datetime2 with 7 decimal places, and
 STOPAT rejects it with "Invalid value specified for STOPAT parameter."

 Copy the value below. You need it in STEP 7b.

 The 30 second wait just widens the gap between the insert and the delete so
 STOPAT has an easy target. Without it you would be aiming at a one-second
 window.
==============================================================================*/

SELECT GETDATE() AS safe_point;     /* <-- COPY THIS. Format: 2026-08-31 15:14:10 */
GO

WAITFOR DELAY '00:00:30';
GO


/*==============================================================================
 STEP 5 - The accident

 DELETE logs every row individually, which is what makes it recoverable to a
 point in time. (TRUNCATE TABLE is minimally logged and behaves differently.)
==============================================================================*/

DELETE FROM dbo.PITR_Demo;
GO

SELECT * FROM dbo.PITR_Demo;        /* empty - the row is gone */
GO


/*==============================================================================
 STEP 6 - ONE log backup, containing BOTH the insert and the delete

 No INIT here. Log backups append by default, and the chain depends on every
 log backup since the full being present and intact.

 Taking a log backup between the insert and the delete would let you stop at
 a file boundary and skip STOPAT entirely. Doing both operations first forces
 STOPAT to stop PARTWAY THROUGH a log, which is the actual feature.
==============================================================================*/

BACKUP LOG AdventureWorks2022
    TO DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_pitr_log.trn'
    WITH CHECKSUM, COMPRESSION;
GO


/*==============================================================================
 STEP 7 - Restore to a NEW database

 Never restore over the original. Two reasons:
   1. You would destroy data the requester did not realise they needed.
   2. Aiming STOPAT is trial and error. Getting it wrong should cost you
      another attempt, not production.
==============================================================================*/

/*
 7a - Find the logical file names inside the backup.

 Every SQL Server file has TWO names:
   logical name    an internal label, e.g. 'AdventureWorks2022'
   physical path   where it sits on disk, e.g. C:\...\AdventureWorks2022.mdf

 MOVE in step 7b needs the LOGICAL names. This is how you find them.
 Look at the 'LogicalName' column in the results.
*/

RESTORE FILELISTONLY
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak';
GO


/*
 7b - Restore the full backup.

 Clauses used here:

   MOVE 'logical' TO 'path'
       The .bak remembers the paths the database used when it was backed up.
       Without MOVE, the restore tries to write to those exact files - which
       AdventureWorks2022 is using right now - and fails.
       Left side  = logical name from 7a. Fixed, you do not choose it.
       Right side = any path you like. These are new files being created.
       Read it as: "write the thing called X to path Y."

   NORECOVERY
       "More restores are coming. Leave the database mid-restore."
       It will show as (Restoring...) in Object Explorer and cannot be
       queried. That is correct, not a hang.

   STATS = 10
       Print progress every 10 percent. Cosmetic.
*/

RESTORE DATABASE AW_PITR_Test
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak'
    WITH
        MOVE 'AdventureWorks2022'     TO N'C:\SQLData\AW_PITR_Test.mdf',      --!REPLACE if 7a showed different logical names
        MOVE 'AdventureWorks2022_log' TO N'C:\SQLData\AW_PITR_Test_log.ldf',  --!REPLACE
        NORECOVERY,
        STATS = 10;
GO


/*
 7c - Replay the log, stopping at the safe point.

 Clauses used here:

   STOPAT = 'datetime'
       Replay the log up to this moment and stop. Everything after it -
       including the delete - is discarded.
       Format: '2026-08-31 15:14:10'. Seconds are plenty.

   RECOVERY
       "That was the last restore. Bring the database online."
       Once you say RECOVERY you cannot apply more logs. If you needed
       another one, you start over from the full backup.
*/

RESTORE LOG AW_PITR_Test
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_pitr_log.trn'
    WITH
        STOPAT = '2026-08-31 15:14:10',     --!REPLACE with the value from STEP 4
        RECOVERY,
        STATS = 10;
GO


/*==============================================================================
 STEP 8 - Did it work?
==============================================================================*/

SELECT 'restored copy' AS source, * FROM AW_PITR_Test.dbo.PITR_Demo;
SELECT 'original'      AS source, * FROM AdventureWorks2022.dbo.PITR_Demo;
GO


/*==============================================================================
 STEP 9 - Clean up

 The restored copy gets a deadline, then it goes. Otherwise it lives forever
 and you back it up and run CHECKDB against it every night.
==============================================================================*/

-- DROP DATABASE AW_PITR_Test;
-- GO
--
-- USE AdventureWorks2022;
-- GO
-- DROP TABLE dbo.PITR_Demo;
-- GO


/*==============================================================================
================================================================================
 TROUBLESHOOTING
================================================================================
==============================================================================*/


/*------------------------------------------------------------------------------
 "Invalid value specified for STOPAT parameter"

 The timestamp has too many decimal places. STOPAT takes datetime, which
 holds 3 - SYSDATETIME() returns 7.
 Fix: trim to whole seconds. '2026-08-31 15:14:10'
------------------------------------------------------------------------------*/


/*------------------------------------------------------------------------------
 "The file cannot be overwritten. It is being used by database X"

 MOVE is missing, or points at a path already in use.
 Fix: run 7a, confirm the logical names, and point the TO paths somewhere
 nothing else is using.
------------------------------------------------------------------------------*/


/*------------------------------------------------------------------------------
 "Directory lookup for the file ... failed"

 The folder on the TO side does not exist. SQL Server will not create it.
 Fix: create the folder, and make sure the SQL Server service account can
 write to it.
------------------------------------------------------------------------------*/


/*------------------------------------------------------------------------------
 AW_PITR_Test is stuck showing (Restoring...)

 Normal after 7b, and normal after a FAILED 7c - the failure does not undo
 anything. Just run 7c again with a corrected value.

 To abandon a restore instead and bring the database online at whatever point
 it reached:
------------------------------------------------------------------------------*/

-- RESTORE DATABASE AW_PITR_Test WITH RECOVERY;
-- GO


/*------------------------------------------------------------------------------
 I lost the safe_point value from STEP 4

 You do NOT need an exotic tool for this. Two approaches:

 1. BOUND THE WINDOW from backup history. Everything in that log backup
    happened between the previous backup and this one's finish time. Run the
    query below, then pick a time inside that window.

 2. GUESS AND CHECK. This is what people actually do in a real incident,
    where nobody wrote down when the bad UPDATE ran. Pick a time, restore,
    query the table. Row present? Done. Row missing? You went too far.

 You cannot rewind a restore. Each attempt starts over from the full backup:
    DROP DATABASE AW_PITR_Test;  then 7b, then 7c with a new time.

 That loop is cheap precisely because you restored to a new name.
------------------------------------------------------------------------------*/

-- SELECT
--     b.database_name,
--     CASE b.type WHEN 'D' THEN 'Full' WHEN 'L' THEN 'Log' ELSE b.type END AS backup_type,
--     b.backup_start_date,
--     b.backup_finish_date
-- FROM msdb.dbo.backupset AS b
-- WHERE b.database_name = N'AdventureWorks2022'
-- ORDER BY b.backup_finish_date DESC;
-- GO


/*------------------------------------------------------------------------------
 I said RECOVERY too early and still need another log

 There is no undo. Drop the restored copy and start again from the full.
 This is why NORECOVERY goes on every restore except the last one.
------------------------------------------------------------------------------*/


/*==============================================================================
 THE SHAPE, WHICH IS THE PART WORTH REMEMBERING
==============================================================================
   1. Restore the full                      NORECOVERY
   2. Restore the differential, if any      NORECOVERY
   3. Restore each log in order             NORECOVERY
   4. The last one                          STOPAT + RECOVERY
   5. Always to a new database name, with MOVE for each file

 The syntax you look up. Reference:
   Search "RESTORE transact-sql site:learn.microsoft.com"
   Or highlight RESTORE in SSMS and press F1.

 THINGS TO TRY NEXT
   - Aim STOPAT after the delete. Watch the row not come back, then redo it
     from the full with an earlier time.
   - Take two log backups instead of one, and restore both in order - the
     first WITH NORECOVERY.
   - Query AW_PITR_Test between 7b and 7c to see what RESTORING looks like.
==============================================================================*/
