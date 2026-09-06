# Runbook 00 — Recovery Planning

**Applies to:** <!-- server / instance -->
**Owner:** <!-- -->
**Last reviewed:** <!-- YYYY-MM-DD -->

**Read this first.** Every other runbook in this set assumes the answers on this
page exist. If they don't, the other runbooks are guesswork.

This is filled in while calm, reviewed on a schedule, and never opened during an
incident except to look something up.

---

## 1. What the business told us

Two questions, four scenarios. Ask them separately. "We can't lose anything"
collapses once someone has to say it four times with costs attached.

| | High availability | Disaster recovery | Corruption | Oops query |
|---|---|---|---|---|
| **How much data can we lose?** (RPO) | | | | |
| **How long can we be down?** (RTO) | | | | |

**Who answered:** <!-- name and title. Not you. -->
**Date agreed:** <!-- -->
**Next review:** <!-- annually, or after any incident -->

<!--
A printable version ships with Brent Ozar's First Responder Kit:
brentozar.com/first-aid

The four columns mean:
  High availability   the server is fine but a component failed
  Disaster recovery   the server, storage, or datacenter is gone
  Corruption          the data is wrong and nobody knows since when
  Oops query          a person ran the wrong statement

Each has its own runbook in this set. Only Corruption and Oops query are
written so far; the other two need infrastructure this server may not have.
-->

**If this table is empty, stop here and go get it filled.** It is the single
highest-value item in this entire set, and nobody but a stakeholder can supply
it.

---

## 2. What is actually installed

Discovered once, recorded here. Runbook 03 section 2.1 has the discovery
queries.

| Question | Answer |
|---|---|
| Backup tooling | <!-- Ola / maintenance plans / third-party / hand-written / none --> |
| Backup jobs — names | <!-- --> |
| CHECKDB tooling | <!-- --> |
| CHECKDB jobs — names | <!-- --> |
| What deletes old backup **files** | <!-- job name, product, or storage policy --> |
| What deletes backup **history** in msdb | <!-- --> |
| Retention **outside** SQL Server | <!-- lifecycle policy, tape rotation, vendor console, or none --> |
| Who owns the storage those backups sit on | <!-- name --> |
| Health-check tooling | <!-- sp_Blitz installed? Y/N --> |

<!--
That "outside SQL Server" row is the one people miss. Storage lifecycle
policies and file-server cleanup scripts delete backups and appear nowhere in
sysjobs. Knowing who owns them is a conversation, not a query.
-->

---

## 3. Retention, derived

Retention is not a preference. It follows from two facts on this page.

### 3.1 The floor

If corruption was caused by a SQL Server bug, checksums did not catch it — the
bug wrote bad data with a matching checksum. So every backup since the last
**clean CHECKDB** is suspect.

**Floor:** a full backup taken before the last clean CHECKDB, plus every
transaction log since.

### 3.2 The margin

The floor assumes someone notices immediately. They won't. Something breaks
Friday, nobody reads the email, you are out Monday to Wednesday, you investigate
Thursday.

**Margin:** however long it realistically takes someone here to notice.

### 3.3 The numbers

| Setting | Value | Derivation |
|---|---|---|
| CHECKDB frequency | <!-- --> | <!-- daily if the window allows, weekly otherwise --> |
| Log backup interval | <!-- --> | = RPO from section 1, corruption column |
| Log backup retention | <!-- --> | ≥ CHECKDB interval + margin. Brent: 10–14 days against weekly CHECKDB |
| Full backup retention | <!-- --> | Must reach past the last clean CHECKDB |
| Where each is configured | <!-- --> | <!-- Ola @CleanupTime, maintenance plan task, vendor setting, storage policy --> |

<!--
If retention feels impossible, the answer is usually MORE FREQUENT CHECKDB,
not more disk. The two are linked: shorter CHECKDB interval → shorter floor.

SQL Server can only express "delete files older than N". Tiered retention
(weekly for six weeks, monthly for six months) must be solved outside it.
-->

---

## 4. Detection controls

SQL Server does **not** alert on corruption, failed backups, or missed
schedules by default. Each row here is something that has to be switched on.

| Control | On? | If off |
|---|---|---|
| Backups use `CHECKSUM` | <!-- --> | Backups of corrupt databases succeed silently |
| Backups continue after error | <!-- --> | One bad database halts the rest |
| CHECKDB covers **all** databases | <!-- --> | Hand-picked lists go stale as databases are added |
| CHECKDB writes an output file | <!-- --> | Failure emails truncate; corruption produces thousands of lines |
| Failure alerts go to a **group**, not a person | <!-- --> | The person leaves; the alerts go nowhere for years |
| Corruption alerts (severity 16+, 823/824/825) | <!-- --> | Script: brentozar.com/go/alert |
| Database Mail configured and tested | <!-- --> | Everything above is silent |
| Health check run on a schedule | <!-- --> | sp_Blitz, or `assess/` queries |

**Who receives the alerts:** <!-- distribution list, not a name -->
**Last confirmed an alert actually arrived:** <!-- date -->

---

## 5. Contacts

| Role | Name | Reach | When |
|---|---|---|---|
| Storage / infrastructure | | | Corruption: heads-up. DR: immediately |
| Application owner | | | Any scenario — they decide whether to stop writes |
| Management | | | Once scope is known |
| Microsoft support | | Contract # | Suspected bug |
| External specialist | | | brentozar.com/go/corruption lists them |
| Whoever can rebuild the server | | | DR |

---

## 6. Rebuild inventory

If this server had to be rebuilt from nothing, what would have to be recreated
by hand? Backups restore databases. They do not restore any of this.

| Item | Where documented | Last verified |
|---|---|---|
| Logins and permissions | <!-- --> | |
| Agent jobs and schedules | <!-- --> | |
| Linked servers | <!-- --> | |
| Trace flags and startup parameters | <!-- --> | |
| Server-level configuration (`sp_configure`) | <!-- --> | |
| Utility stored procedures in `master` | <!-- --> | |
| Certificates and encryption keys | <!-- --> | |
| Patch level | <!-- --> | |

<!--
`assess/01_instance_orientation.sql` and the access query in `05` produce some
of this. The rest is scripted out from SSMS or captured by sp_Blitz. dbatools
(dbatools.io) can export all of it if PowerShell is an option.

This is the "install checklist" from the Restores module. Without it, a server
rebuild means reconstructing from memory.
-->

---

## 7. Review log

| Date | Reviewed by | What changed |
|---|---|---|
| | | |

<!--
Review triggers: annually; after any incident; after any change to backup
tooling; when the application owner or storage owner changes.
-->
