# Runbook 01 — Backup Strategy

**Applies to:** <!-- server / instance -->
**Owner:** <!-- -->
**Last reviewed:** <!-- -->

**Requires:** Runbook 00, section 1 filled in. Every decision here derives from
the RPO and RTO.

This runbook covers designing backups for a server that has none, or replacing
backups you don't trust. It is procedure, not tutorial — the reasoning is in the
comments.

---

## 1. Decide the recovery model

Per database, not per server.

| RPO from Runbook 00 | Recovery model | Consequence |
|---|---|---|
| A day is acceptable | **SIMPLE** | Daily fulls only. Log manages itself. No point-in-time recovery |
| Less than a day | **FULL** | Log backups required. **Skip them and the log grows until the disk fills** |

```sql
SELECT name, recovery_model_desc FROM sys.databases ORDER BY name;
```

```sql
ALTER DATABASE <db> SET RECOVERY FULL;                            --!REPLACE
```

<!--
Switching to FULL does not start the log chain. The first full backup after the
switch does. Until then the database reports FULL and behaves as SIMPLE, and
log backups fail. Take a full immediately after the ALTER.

Also check `model`. New databases inherit its recovery model. If `model` is
FULL and nobody sets up log backups for new databases, they become time bombs.
-->

**Decision recorded:**

| Database | Model | Why |
|---|---|---|
| | | |

---

## 2. Decide the schedule

Derived, not chosen.

| Backup | When | Derivation |
|---|---|---|
| **Full** | <!-- --> | After the last batch of the day, before staff arrive. Early enough that a failure email is seen before business hours |
| **Differential** | <!-- or none --> | Only if fulls are too slow to run daily. Adds a link to the restore chain |
| **Log** | Every <!-- --> | = RPO. Frequent small log backups are *less* disruptive than infrequent large ones |
| **CHECKDB** | <!-- --> | Daily if the window allows; weekly otherwise. Sets the retention floor |

<!--
Order within the maintenance window: backup FIRST, then CHECKDB, then index
maintenance. If the window runs long, the backup is already done.

CHECKDB and full backup at the same moment compete for I/O and CHECKDB creates
an internal snapshot. Stagger them.
-->

---

## 3. Decide where backups go

| Question | Answer |
|---|---|
| Path | <!-- prefer UNC: \\server\share --> |
| Is that a different physical machine from the SQL Server? | <!-- Y/N — if N, the server dying takes the backups with it --> |
| Is it a different disk from the data files? | <!-- check with sys.master_files --> |
| Service account has Modify? | <!-- backups run as the SERVICE, not you --> |
| Off-site copy | <!-- how, and how often --> |

<!--
"Operating system error 5 (Access is denied)" means the service account cannot
write there. It is the most common first failure and it happens at 2am.

A UNC path to a share hosted on the same physical box gives the appearance of
separation without the protection. Confirm with whoever owns the storage.
-->

---

## 4. The commands

Every backup gets these three, without exception:

| Option | Why |
|---|---|
| `CHECKSUM` | Verifies pages on the way out. Without it, corrupt backups succeed silently. 1–2% cost |
| `COMPRESSION` | Smaller, usually faster. Set it in the command, not the server default — someone changes the default |
| `CONTINUE_AFTER_ERROR` | One bad database does not halt the rest |

### 4.1 Full

```sql
BACKUP DATABASE <db>                                              --!REPLACE
    TO DISK = N'<path>\<db>_FULL_<yyyymmdd_hhmmss>.bak'           --!REPLACE
    WITH CHECKSUM, COMPRESSION, CONTINUE_AFTER_ERROR, STATS = 10;
```

<!--
No INIT. Timestamped filenames mean nothing overwrites anything; retention is
handled by deleting old files. INIT on a full is safe but unnecessary with
unique names. INIT on a LOG backup discards earlier logs and breaks the chain.
-->

### 4.2 Log

```sql
BACKUP LOG <db>                                                   --!REPLACE
    TO DISK = N'<path>\<db>_LOG_<yyyymmdd_hhmmss>.trn'            --!REPLACE
    WITH CHECKSUM, COMPRESSION, CONTINUE_AFTER_ERROR;
```

### 4.3 Automated

Do not hand-schedule these. Use one of:

| Tool | When |
|---|---|
| **Ola Hallengren** — `ola.hallengren.com` | Default choice. Free, T-SQL, no SSIS dependency. Creates jobs; **you** attach schedules |
| Maintenance Plans | If nobody can read T-SQL. Needs SSIS in SSMS 21+ |
| Third-party (LiteSpeed, SQL Safe, etc.) | If object-level restore or log reading is required |

**Ola call, recorded here:**

```sql
EXEC master.dbo.DatabaseBackup
    @Databases    = N'USER_DATABASES',   /* never a hand-picked list */
    @Directory    = N'<path>',                                    --!REPLACE
    @BackupType   = N'FULL',              /* or LOG */
    @Verify       = N'Y',                 /* !OPT: skip on very large or very many DBs */
    @Compress     = N'Y',
    @CheckSum     = N'Y',
    @ChangeBackupType = N'Y',             /* takes a full if a log/diff cannot run */
    @CleanupTime  = <hours>;              --!REPLACE from Runbook 00 section 3
```

<!--
@Databases = 'USER_DATABASES' not a list. Someone adds a database next month
and it is covered without anyone remembering.

SYSTEM_DATABASES need their own job. master holds every login; msdb holds every
job and all backup history. Lose them and you rebuild the instance from memory.
-->

---

## 5. Retention

From Runbook 00 section 3. Recorded here so this runbook stands alone:

| What | Keep | Configured where |
|---|---|---|
| Full backup files | <!-- --> | <!-- --> |
| Log backup files | <!-- --> | <!-- --> |
| Backup history (`msdb`) | <!-- --> | `sp_delete_backuphistory` |
| Job history (`msdb`) | <!-- --> | `sp_purge_jobhistory` |
| Job output files | <!-- --> | Ola's Output File Cleanup, or by hand |

<!--
Three of these are EVIDENCE, not backups. Purge them too aggressively and you
cannot answer "when did this start failing."
-->

---

## 6. Verify

A backup is a hypothesis until restored.

| Check | How often | How |
|---|---|---|
| File readable and checksum-clean | After every backup, or weekly | `RESTORE VERIFYONLY ... WITH CHECKSUM` |
| Chain restorable end to end | <!-- monthly? --> | Restore to a scratch server, run CHECKDB on the copy |
| History matches expectation | Weekly | `assess/02_backup_history.sql` — zero concerns is the target |
| Alerts actually arrive | Quarterly | Force a failure. Confirm someone got the email |

<!--
Restoring to a scratch server and running CHECKDB there tests the backup, the
chain, and corruption detection in one pass, on hardware that is not
production. It is the only test that proves everything.
-->

---

## 7. Sign-off

| Item | Done | Date | By |
|---|---|---|---|
| Recovery models set per section 1 | | | |
| Schedules attached to every job | | | |
| Failure alerts go to a group and were tested | | | |
| Retention configured per section 5 | | | |
| First full backup completed | | | |
| `assess/02_backup_history.sql` shows zero concerns | | | |
| One restore performed to a new name and CHECKDB'd clean | | | |

**Until every row is ticked, this server is not backed up.** A job that exists
without a schedule, or a schedule without an alert, is the appearance of a
backup.

---

## 8. Change log

| Date | Change | Why |
|---|---|---|
| | | |
