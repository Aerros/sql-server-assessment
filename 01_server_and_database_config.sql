/*
================================================================================
 01 - INSTANCE ORIENTATION
================================================================================
 Question:   What is this server, and how is it configured?
 Safety:     All read-only and cheap. Safe to run the whole file with F5.
 Run when:   First contact with a server you did not build.
================================================================================
*/


/* What am I connected to? Version, edition, patch level. */
SELECT
    @@SERVERNAME                        AS server_name,
    SERVERPROPERTY('ProductVersion')    AS product_version,
    SERVERPROPERTY('ProductLevel')      AS patch_level,
    SERVERPROPERTY('Edition')           AS edition,
    SERVERPROPERTY('EngineEdition')     AS engine_edition;


/*
 Every database, its recovery model, and what is blocking log reuse.
 log_reuse_wait_desc = 'LOG_BACKUP' means the log cannot free space until a
 log backup runs. FULL recovery + no log backups = the log grows until the
 disk fills. Cross-reference against file 02 before concluding anything.
*/
SELECT
    name,
    state_desc,
    recovery_model_desc,
    log_reuse_wait_desc,
    compatibility_level,
    create_date
FROM sys.databases
ORDER BY name;


/*
 Where do the files live, how big are they, and how do they grow?
 Watch for: data and log on the same physical disk, percentage autogrowth,
 anything sitting on C.
*/
SELECT
    DB_NAME(database_id)                AS database_name,
    type_desc                           AS file_type,
    name                                AS logical_name,
    physical_name,
    size / 128.0                        AS size_mb,          /* pages are 8KB */
    CASE max_size
        WHEN -1 THEN 'Unlimited'
        WHEN  0 THEN 'No growth'
        ELSE CAST(max_size / 128.0 AS varchar(20)) + ' MB'
    END                                 AS max_size,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS varchar(10)) + ' %'
        ELSE CAST(growth / 128.0 AS varchar(20)) + ' MB'
    END                                 AS growth
FROM sys.master_files
ORDER BY database_name, file_type DESC;
