# Drill — Backup Strategy

**Companion to:** `RUNBOOK_01_backup_strategy.md`
**Time:** about ninety minutes
**Prerequisite:** AdventureWorks2022 restored. Ola's scripts installed. Any
existing Ola schedules disabled so they do not interfere.

One scenario, start to finish: a server with no backup strategy, a business
that has just told you what it needs, and you designing and proving the answer.

**Predict before every step.** Two columns in a scratch file: what I expected,
what happened.

---

## The scenario

You have just taken over a server. The application owner tells you:

> Staff enter data 8am to 6pm. Losing more than **15 minutes** of it would be
> serious. We could tolerate being down for **two hours**. A batch job finishes
> around **11pm** and nothing touches the database after that.

Nobody has ever backed it up properly. There are some old `.bak` files in a
folder from someone who left.

---

## Part 1 — Assess before you touch anything

Run, in order:

- `assess/01_instance_orientation.sql`
- `assess/02_backup_history.sql`
- `assess/05_health_checks.sql`

**1.1** Write down every concern `02` raises for AdventureWorks2022 and the
system databases. This is your "before."

**1.2** From `01`: what recovery model is AdventureWorks2022 in right now? What
about `model`? Why does `model` matter for databases that do not exist yet?

**1.3** From `05`: has CHECKDB ever completed cleanly? What is
`dbi_dbccLastKnownGood`?

*Do not fix anything yet.* The point is to have a documented starting state.

---

## Part 2 — Derive the design

Open `RUNBOOK_01_backup_strategy.md`. Fill in sections 1, 2, and 3 from the
scenario. No looking things up — the answers follow from 15 minutes, 2 hours,
and 11pm.

**2.1** Recovery model, and why.

**2.2** Full backup time. What breaks if you pick 2am? What breaks if you pick
5pm?

**2.3** Log backup interval. What is the *direct* consequence of doubling it?
(Not performance — what does the business lose?)

**2.4** CHECKDB frequency, and therefore the retention floor from Runbook 00
section 3.

**2.5** Where do backups go on this laptop, and what would be different on a
real server?

Write all five answers before proceeding. Then compare against the reasoning in
the runbook comments.

---

## Part 3 — Implement

### 3.1 Recovery model

```sql
ALTER DATABASE AdventureWorks2022 SET RECOVERY FULL;
```

*Predict:* run `02` now. Which flag appears, and why does it appear *before* you
have done anything wrong?

### 3.2 Seed the chain

```sql
BACKUP DATABASE AdventureWorks2022
    TO DISK = N'C:\SQLBackups\Drill\AW_seed.bak'
    WITH CHECKSUM, COMPRESSION, STATS = 10;
```

Run `02` again. *Which flags cleared? Which remain?*

### 3.3 Ola, configured to your design

Edit the job steps (right-click job → Properties → Steps → Edit) so the
parameters match what you derived in Part 2. At minimum:

- `@Directory` — your path
- `@CleanupTime` — from your retention floor plus margin, **in hours**
- `@CheckSum = 'Y'`, `@Compress = 'Y'`
- `@ChangeBackupType = 'Y'` on the LOG job

*Predict:* what happens on the first LOG run if you forget `@ChangeBackupType`
and a database in FULL recovery has never had a full backup?

### 3.4 Schedules

On a compressed timeline so you can watch it: full every 5 minutes, log every
1 minute, CHECKDB every 10 minutes. Keep the *order* from your design.

Right-click job → Properties → Schedules → New. **Occurs every** N minutes, not
"Occurs once at."

*Predict:* after 10 minutes, how many `.bak` and `.trn` files exist? Count them
before you look.

### 3.5 Run 02 again

*Predict first.* Then run it.

This is the "after." Compare against Part 1.1 line by line. Every concern that
cleared, you can explain why. Every one that remains, you can explain why it is
acceptable or what would fix it.

---

## Part 4 — Break it, then prove it

### 4.1 Retention that destroys evidence

Set `@CleanupTime = 1` on the FULL job — one hour — and wait past the hour.

*Predict:* what is in the FULL folder now? What does `02` say? Is it a flag, or
is it silence? Which is worse?

Set it back.

### 4.2 The disabled job

Disable the LOG job. Wait ten minutes. Run `02` and the job-list query in `05`.

*Predict:* which one notices, and why is the other one blind?

Re-enable it.

### 4.3 Verify a backup

```sql
RESTORE VERIFYONLY FROM DISK = N'<any Ola .bak>' WITH CHECKSUM;   --!REPLACE
```

Then delete that file in Explorer and run the same command.

*Predict:* what does `02` say about the backup whose file you just deleted?

### 4.4 The only real test

Restore the newest full plus every log since, to a new name, using only Ola's
files. Work out the chain from the folder tree. Then:

```sql
DBCC CHECKDB (N'AW_Verify') WITH NO_INFOMSGS, EXTENDED_LOGICAL_CHECKS;
```

Time how long it took from opening the folder to a clean CHECKDB. **Is it under
the two-hour RTO?** What would it have been at 3am, on a database a thousand
times larger, with no `L01` file to copy from?

---

## Part 5 — Sign off

Fill in section 7 of `RUNBOOK_01_backup_strategy.md`. Tick only what you have
actually done.

The row that will be hardest to tick honestly is "failure alerts go to a group
and were tested," because you have not set up Database Mail. **Leave it
unticked.** A runbook that says "not done" is worth more than one that lies.

Then write in section 8 what you changed and why — the retention number, the
schedule, the recovery model — with the derivation. That is the "what changed
and why" someone inherits.

---

## Cleanup

Disable the compressed schedules. Delete `C:\SQLBackups\Drill\` and Ola's
output tree. Drop `AW_Verify`.

---

## Questions to be able to answer afterwards

1. Why FULL recovery, and what exactly happens to the log if you set it and
   walk away?
2. What does doubling the log interval cost the business, in one sentence?
3. Why is the full backup time derived from the batch job, not from convenience?
4. Which is more dangerous: a disabled backup job, or a retention setting too
   short? Why does your query catch one and not the other?
5. What does "the server is backed up" actually require, listed as a checklist?
   How many items were true before you started?
