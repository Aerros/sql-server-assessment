/*
================================================================================
 06 - POINT IN TIME RECOVERY DEMO (STOPAT)
================================================================================
 Goal:       Recover a row that was inserted and then deleted, by restoring to
             a moment between the two.

 Safety:     Writes. Runs against AdventureWorks2022 only, and restores to a
             NEW database name - never over the original. Run one step at a
             time, in order. Do not F5 the whole file.

 Why one log backup and not two:
   If you back up the log between the insert and the delete, the first log
   ends before the delete happened - so you could just stop there and STOPAT
   would be doing nothing. Doing both operations first, then taking a single
   log backup, forces STOPAT to stop PARTWAY THROUGH a log backup, which is
   the actual feature.

 Prerequisites:
   - AdventureWorks2022 in FULL recovery with a full backup already taken
     (00_lab_setup.sql)
   - C:\SQLBackups\AdventureWorks2022\FULL\ and \LOG\ exist
================================================================================
*/


/* ---------------------------------------------------------------------------
 STEP 1 - Create something to lose.
 A scratch table, so nothing real is touched.
--------------------------------------------------------------------------- */

USE AdventureWorks2022;
GO

CREATE TABLE dbo.PITR_Demo (
    id          int IDENTITY(1,1) PRIMARY KEY,
    note        nvarchar(100),
    created_at  datetime2 DEFAULT SYSDATETIME()
);
GO


/* ---------------------------------------------------------------------------
 STEP 2 - Fresh full backup. This is the baseline the restore starts from.

 A new full backup does NOT break the log chain - the chain continues.
 Written to its own file so the seed backup from lab setup stays intact.
 WITH INIT overwrites this file if you re-run the demo, which is what you want.
--------------------------------------------------------------------------- */

BACKUP DATABASE AdventureWorks2022
    TO DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak'
    WITH INIT, CHECKSUM, COMPRESSION;
GO


/* ---------------------------------------------------------------------------
 STEP 3 - Insert the row you are going to lose.
--------------------------------------------------------------------------- */

INSERT INTO dbo.PITR_Demo (note) VALUES (N'This row must survive');
GO

SELECT * FROM dbo.PITR_Demo;    /* confirm it is there */
GO


/* ---------------------------------------------------------------------------
 STEP 4 - Record the time, then WAIT about 30 seconds.

 Copy the value this returns. You will paste it into STEP 7.
 The wait just makes the timestamps obviously different - without it you are
 trying to aim STOPAT at a one-second window.
--------------------------------------------------------------------------- */

SELECT SYSDATETIME() AS safe_point;     /* <-- COPY THIS VALUE */
GO

WAITFOR DELAY '00:00:30';               /* or just count to thirty */
GO


/* ---------------------------------------------------------------------------
 STEP 5 - The accident.
--------------------------------------------------------------------------- */

DELETE FROM dbo.PITR_Demo;
GO

SELECT * FROM dbo.PITR_Demo;    /* empty - the row is gone */
GO


/* ---------------------------------------------------------------------------
 STEP 6 - ONE log backup, containing BOTH the insert and the delete.

 Note: no INIT here. Log backups append by default, and the log chain depends
 on every log backup since the full being available. INIT on a log file would
 discard earlier logs and break the chain.
--------------------------------------------------------------------------- */

BACKUP LOG AdventureWorks2022
    TO DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_pitr_log.trn'
    WITH CHECKSUM, COMPRESSION;
GO


/* ---------------------------------------------------------------------------
 STEP 7 - Restore to a NEW database, stopping at the safe point.

 First confirm the logical file names inside the backup. Usually
 'AdventureWorks2022' and 'AdventureWorks2022_log', but check rather than
 assume - MOVE below has to match exactly.
--------------------------------------------------------------------------- */

RESTORE FILELISTONLY
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak';
GO


/*
 7a - Restore the full backup WITH NORECOVERY.

 NORECOVERY means "more restores are coming, leave the database mid-restore."
 It will sit in RESTORING state and cannot be queried until step 7b.

 MOVE is required because the original database is still online and using its
 files - without MOVE the restore tries to overwrite them and fails.
*/

RESTORE DATABASE AW_PITR_Test
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\FULL\AW_pitr_full.bak'
    WITH
        MOVE 'AdventureWorks2022'     TO N'C:\SQLBackups\AW_PITR_Test.mdf',   --!REPLACE if FILELISTONLY showed different names
        MOVE 'AdventureWorks2022_log' TO N'C:\SQLBackups\AW_PITR_Test_log.ldf',
        NORECOVERY,
        STATS = 10;
GO


/*
 7b - Replay the log, but stop at the safe point.

 STOPAT stops partway through this log backup: after the insert committed,
 before the delete did.

 RECOVERY (not NORECOVERY) means "that is the last restore, bring it online."
 Once you say RECOVERY you cannot apply more logs - you would start over.
*/

RESTORE LOG AW_PITR_Test
    FROM DISK = N'C:\SQLBackups\AdventureWorks2022\LOG\AW_pitr_log.trn'
    WITH
        STOPAT = '2026-08-30 14:23:45',     --!REPLACE with the value from STEP 4
        RECOVERY,
        STATS = 10;
GO


/* ---------------------------------------------------------------------------
 STEP 8 - Did it work?

 The restored copy should have the row. The original should not.
--------------------------------------------------------------------------- */

SELECT 'restored copy' AS source, * FROM AW_PITR_Test.dbo.PITR_Demo;
SELECT 'original'      AS source, * FROM AdventureWorks2022.dbo.PITR_Demo;
GO


/* ---------------------------------------------------------------------------
 STEP 9 - Clean up.

 The module's own advice: the restored copy gets a deadline, then it goes.
 Otherwise it lives forever and you back it up and CHECKDB it every night.
--------------------------------------------------------------------------- */

-- DROP DATABASE AW_PITR_Test;
-- GO
--
-- USE AdventureWorks2022;
-- GO
-- DROP TABLE dbo.PITR_Demo;
-- GO


/*
================================================================================
 WHAT TO NOTICE
================================================================================
 - The row came back from a log backup taken AFTER it was already deleted.
   The delete is in that file too; STOPAT simply stops before replaying it.

 - NORECOVERY on every restore except the last. RECOVERY ends the chain. Say
   RECOVERY too early and you start over from the full backup.

 - This only worked because the database was in FULL recovery with an unbroken
   log chain. In SIMPLE there is no log backup, so there is no point in time to
   return to - the row is gone for good.

 - The restore went to a NEW database name. The original was never touched, so
   if you had aimed STOPAT wrong you could simply try again.

 THINGS TO TRY NEXT
 - Aim STOPAT after the delete. The row will not be there. Restore again with
   an earlier time - and notice you have to start from the full backup.
 - Take two log backups instead of one and restore both in order, the first
   WITH NORECOVERY.
 - Try to query AW_PITR_Test between 7a and 7b, to see what RESTORING state
   looks like.
================================================================================
*/
