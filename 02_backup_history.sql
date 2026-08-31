/*
================================================================================
 BACKUP EVIDENCE - COMPREHENSIVE
================================================================================
 Question:   For every database, is there a usable backup, taken by this
             instance, written somewhere reachable, and recent enough?

 Safety:     Read-only. Select the WHOLE block - the DECLAREs must run with it.

 READING first_action AND all_concerns
   Actions come in two kinds, distinguished by prefix:

     (no prefix)  Definite. The condition is wrong regardless of policy, and
                  the fix has no meaningful downside. Do it.

     !OPT:        Judgment call. The right answer depends on a recovery point
                  objective, a budget, or a restore strategy this query does
                  not know about. Decide, then act - do not just follow it.

   Every !OPT: item traces back to something a person has to decide. "Schedule
   log backups, or switch to SIMPLE" assumes somebody has said how much data
   loss is acceptable. Nobody has told this query that.

   Always read the evidence columns before acting on any flag.

 KNOWN LIMIT
   This reports what SQL Server RECORDED, not what exists on disk now. A path
   on a decommissioned file server looks identical to a live one. Only
   RESTORE VERIFYONLY - or an actual restore - closes that gap.

 SOURCES
   sys.databases              recovery model and state
   sys.master_files           where DATA files live, to spot same-drive backups
   msdb.dbo.backupset         what was backed up, when, by which server, how
   msdb.dbo.backupmediafamily where the backup file was written

 STRUCTURE
   db_drives   -> drive letters per database
   ranked      -> every backup, ranked newest-first within database and type
   latest      -> newest of each type, with its device path attached
   summary     -> one row per database, types flattened into columns
   flagged     -> numeric 1/0 flags, conditions stated ONCE
   actioned    -> action text derived from the flags, no conditions repeated
   final       -> evidence, flags, concerns, first_action, concern_count

 PERFORMANCE
   ROW_NUMBER sorts within each database/type partition. Index backupset to
   match that order and the sort disappears entirely - the window function
   reads the first row of each partition and stops, so history size stops
   mattering. Indexing msdb is supported and normal:

     CREATE NONCLUSTERED INDEX IX_backupset_db_type_finish
         ON msdb.dbo.backupset (database_name, type, backup_finish_date DESC);

   Trimming history with sp_delete_backuphistory is worth doing as routine
   housekeeping, but it is NOT the fix for this query being slow.
================================================================================
*/

DECLARE @full_max_age_days  int = 7;    --!REPLACE - policy, not fact
DECLARE @log_max_age_hours  int = 24;   --!REPLACE - policy, not fact


WITH

/* Drive letters holding each database's data and log files. Used to flag
   backups written to the same drive, where one disk failure takes both. */
db_drives AS (
    SELECT
        database_name,
        STRING_AGG(drive, ',') AS data_drives
    FROM (
        SELECT DISTINCT
            DB_NAME(database_id)            AS database_name,
            UPPER(LEFT(physical_name, 2))   AS drive        /* 'C:' etc */
        FROM sys.master_files
    ) AS d
    GROUP BY database_name
),

/* Rank every backup newest-first within each database and type.
   type: D = full, I = differential, L = log. */
ranked AS (
    SELECT
        b.database_name,
        b.type,
        b.backup_finish_date,
        b.server_name,                      /* which INSTANCE took it */
        b.machine_name,                     /* which HOST took it */
        b.is_copy_only,
        b.is_damaged,
        b.has_backup_checksums,
        b.backup_size,
        b.media_set_id,
        ROW_NUMBER() OVER (
            PARTITION BY b.database_name, b.type
            ORDER BY b.backup_finish_date DESC
        ) AS rn
    FROM msdb.dbo.backupset AS b
),

/* Newest of each type only, with the device path attached.
   A striped backup has several rows in backupmediafamily, so the paths are
   concatenated in a subquery - joining would multiply the result rows. */
latest AS (
    SELECT
        r.*,
        (
            SELECT STRING_AGG(m.physical_device_name, ' | ')
            FROM msdb.dbo.backupmediafamily AS m
            WHERE m.media_set_id = r.media_set_id
        ) AS device_list
    FROM ranked AS r
    WHERE r.rn = 1
),

/* One row per database, types flattened into columns.
   LEFT JOIN from sys.databases so databases with no backup history still
   appear - as NULLs - rather than vanishing from the result. */
summary AS (
    SELECT
        d.name                          AS database_name,
        d.recovery_model_desc,
        d.state_desc,
        dd.data_drives,

        MAX(CASE WHEN l.type = 'D' THEN l.backup_finish_date END)   AS last_full,
        MAX(CASE WHEN l.type = 'I' THEN l.backup_finish_date END)   AS last_diff,
        MAX(CASE WHEN l.type = 'L' THEN l.backup_finish_date END)   AS last_log,

        MAX(CASE WHEN l.type = 'D' THEN l.server_name END)          AS full_taken_by_server,
        MAX(CASE WHEN l.type = 'D' THEN l.machine_name END)         AS full_taken_by_machine,
        MAX(CASE WHEN l.type = 'D' THEN l.device_list END)          AS full_written_to,
        MAX(CASE WHEN l.type = 'L' THEN l.device_list END)          AS log_written_to,

        MAX(CASE WHEN l.type = 'D' THEN CAST(l.is_copy_only         AS int) END) AS full_is_copy_only,
        MAX(CASE WHEN l.type = 'D' THEN CAST(l.is_damaged           AS int) END) AS full_is_damaged,
        MAX(CASE WHEN l.type = 'D' THEN CAST(l.has_backup_checksums AS int) END) AS full_has_checksums,
        MAX(CASE WHEN l.type = 'D' THEN l.backup_size / 1048576.0 END)           AS full_size_mb
    FROM sys.databases AS d
    LEFT JOIN db_drives AS dd
           ON dd.database_name = d.name
    LEFT JOIN latest AS l
           ON l.database_name = d.name
    WHERE d.name <> 'tempdb'                /* tempdb is never backed up */
    GROUP BY d.name, d.recovery_model_desc, d.state_desc, dd.data_drives
),

/* Numeric flags. Every condition is stated exactly once, here.
   NULL comparisons evaluate to UNKNOWN, so the age flags do not double-fire
   with never_backed_up. */
flagged AS (
    SELECT
        *,
        CASE WHEN last_full IS NULL
             THEN 1 ELSE 0 END AS f_never_backed_up,

        CASE WHEN state_desc <> 'ONLINE'
             THEN 1 ELSE 0 END AS f_not_online,

        /* Written to the null device: the backup "succeeded" and the file went
           nowhere. In FULL recovery it also truncated the log, silently
           breaking the chain. */
        CASE WHEN full_written_to LIKE '%NUL%' OR log_written_to LIKE '%NUL%'
             THEN 1 ELSE 0 END AS f_backup_to_nul,

        /* Newest full was taken by a different instance - usually history that
           arrived with a restore, meaning no local backup has ever been taken. */
        CASE WHEN full_taken_by_server IS NOT NULL
              AND full_taken_by_server <> @@SERVERNAME
             THEN 1 ELSE 0 END AS f_foreign_backup,

        CASE WHEN full_is_damaged = 1
             THEN 1 ELSE 0 END AS f_damaged,

        /* FULL recovery with no log backup: the log grows until the disk fills. */
        CASE WHEN recovery_model_desc = 'FULL' AND last_log IS NULL
             THEN 1 ELSE 0 END AS f_full_no_log,

        /* COPY_ONLY cannot serve as the base for a differential, so a
           full-plus-diff restore plan is broken. */
        CASE WHEN full_is_copy_only = 1
             THEN 1 ELSE 0 END AS f_latest_full_copy_only,

        CASE WHEN last_full < DATEADD(DAY, -@full_max_age_days, GETDATE())
             THEN 1 ELSE 0 END AS f_stale_full,

        CASE WHEN recovery_model_desc = 'FULL'
              AND last_log < DATEADD(HOUR, -@log_max_age_hours, GETDATE())
             THEN 1 ELSE 0 END AS f_stale_log,

        /* Without CHECKSUM, corruption can be written into the backup with
           nothing noticing. */
        CASE WHEN full_has_checksums = 0
             THEN 1 ELSE 0 END AS f_no_checksum,

        /* Backup on a drive that also holds the data files.
           UNC paths start with \\ so they never match a drive letter. */
        CASE WHEN data_drives IS NOT NULL
              AND full_written_to IS NOT NULL
              AND CHARINDEX(UPPER(LEFT(full_written_to, 2)), data_drives) > 0
             THEN 1 ELSE 0 END AS f_backup_on_data_drive
    FROM summary
),

/* Action text derived from the flags. No condition is repeated - each CASE
   reads a flag computed above. A CASE with no ELSE returns NULL, which is
   what makes COALESCE and CONCAT_WS work cleanly below.

   Unprefixed = definite. !OPT: = depends on a decision this query cannot make. */
actioned AS (
    SELECT
        *,
        CASE WHEN f_backup_to_nul = 1
             THEN 'Stop the NUL backup. Take a real full immediately - the log chain is broken.'
             END AS a_backup_to_nul,

        CASE WHEN f_never_backed_up = 1
             THEN 'Take a full backup now. This database has never been backed up here.'
             END AS a_never_backed_up,

        CASE WHEN f_not_online = 1
             THEN 'Investigate the database state before anything else.'
             END AS a_not_online,

        CASE WHEN f_damaged = 1
             THEN 'Do not rely on this backup. Take a new full and verify it.'
             END AS a_damaged,

        CASE WHEN f_foreign_backup = 1
             THEN 'No local backup exists - this history came from another server. Take a full backup now.'
             END AS a_foreign_backup,

        /* Depends on the recovery point objective. Nobody has stated one. */
        CASE WHEN f_full_no_log = 1
             THEN '!OPT: Schedule log backups, or switch to SIMPLE if the data loss is acceptable.'
             END AS a_full_no_log,

        /* "Stale" is measured against @full_max_age_days, which is a guess
           until somebody sets a real tolerance. */
        CASE WHEN f_stale_full = 1
             THEN '!OPT: Check why the full backup schedule is not running, or confirm the age is acceptable.'
             END AS a_stale_full,

        /* Only matters if differentials are part of the restore plan. */
        CASE WHEN f_latest_full_copy_only = 1
             THEN '!OPT: If differentials are in use, take a non-COPY_ONLY full to re-base them.'
             END AS a_latest_full_copy_only,

        /* Measured against @log_max_age_hours - same caveat as stale_full. */
        CASE WHEN f_stale_log = 1
             THEN '!OPT: Check why the log backup schedule is not running, or confirm the age is acceptable.'
             END AS a_stale_log,

        /* Depends on what storage exists and what it costs. */
        CASE WHEN f_backup_on_data_drive = 1
             THEN '!OPT: Move backups off the data drive if separate storage is available - one disk failure currently takes both.'
             END AS a_backup_on_data_drive,

        CASE WHEN f_no_checksum = 1
             THEN 'Add WITH CHECKSUM to the backup job.'
             END AS a_no_checksum
    FROM flagged
)

SELECT
    /* ---------- identity ---------- */
    database_name,
    recovery_model_desc,
    state_desc,

    /* ---------- evidence: read these before trusting any flag ---------- */
    last_full,
    last_diff,
    last_log,
    DATEDIFF(DAY,  last_full, GETDATE())    AS full_age_days,
    DATEDIFF(HOUR, last_log,  GETDATE())    AS log_age_hours,
    full_taken_by_server,
    full_taken_by_machine,
    full_written_to,
    log_written_to,
    data_drives,
    full_size_mb,

    /* ---------- what to do first: severity order is the argument order ---------- */
    COALESCE(
        a_backup_to_nul,
        a_never_backed_up,
        a_not_online,
        a_damaged,
        a_foreign_backup,
        a_full_no_log,
        a_stale_full,
        a_latest_full_copy_only,
        a_stale_log,
        a_backup_on_data_drive,
        a_no_checksum
    )                                       AS first_action,

    /* ---------- everything wrong, not just the first ---------- */
    CONCAT_WS('; ',
        a_backup_to_nul,
        a_never_backed_up,
        a_not_online,
        a_damaged,
        a_foreign_backup,
        a_full_no_log,
        a_stale_full,
        a_latest_full_copy_only,
        a_stale_log,
        a_backup_on_data_drive,
        a_no_checksum
    )                                       AS all_concerns,

    /* ---------- scannable flags ---------- */
    CASE WHEN f_backup_to_nul         = 1 THEN 'YES' ELSE '' END AS backup_to_nul,
    CASE WHEN f_never_backed_up       = 1 THEN 'YES' ELSE '' END AS never_backed_up,
    CASE WHEN f_not_online            = 1 THEN 'YES' ELSE '' END AS not_online,
    CASE WHEN f_damaged               = 1 THEN 'YES' ELSE '' END AS damaged,
    CASE WHEN f_foreign_backup        = 1 THEN 'YES' ELSE '' END AS foreign_backup,
    CASE WHEN f_full_no_log           = 1 THEN 'YES' ELSE '' END AS full_recovery_no_log,
    CASE WHEN f_stale_full            = 1 THEN 'YES' ELSE '' END AS stale_full,
    CASE WHEN f_latest_full_copy_only = 1 THEN 'YES' ELSE '' END AS latest_full_copy_only,
    CASE WHEN f_stale_log             = 1 THEN 'YES' ELSE '' END AS stale_log,
    CASE WHEN f_backup_on_data_drive  = 1 THEN 'YES' ELSE '' END AS backup_on_data_drive,
    CASE WHEN f_no_checksum           = 1 THEN 'YES' ELSE '' END AS no_checksum,

    /* ---------- sortable severity ---------- */
    f_backup_to_nul + f_never_backed_up + f_not_online + f_damaged
      + f_foreign_backup + f_full_no_log + f_stale_full
      + f_latest_full_copy_only + f_stale_log + f_backup_on_data_drive
      + f_no_checksum                       AS concern_count
FROM actioned
ORDER BY concern_count DESC, database_name;
