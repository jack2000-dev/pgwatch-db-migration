# Reading the migration dashboards

This guide is for operators monitoring logical replication from an AWS or
DigitalOcean publisher to a MyCloud (OpenStack) subscriber. Grafana shows
replication health. The separate data validator compares application rows.

## Start with the fleet overview

Open **PostgreSQL Migrations → PostgreSQL Migration Fleet Overview** in
Grafana. Each row is one source PostgreSQL instance → target PostgreSQL
instance. Profiles are grouped by their explicit `provider` and `instance`
tags; each database migration needs its own shared `migration_pair` tag.
Click the source instance to inspect its databases.

| Column | How to read it |
| --- | --- |
| Source/target provider and instance | The two servers in this migration path. Click the source instance for the database table. |
| Migrations | Number of database/slot relationships in this instance pair. |
| Health status | Worst current replication-health state across those relationships. |
| Cutover status | `READY` only if every relationship is READY; otherwise the most important blocking state. |
| Status counts | Number of relationships in each health/cutover state. Use these when a mixed instance has one rollup label. |
| Max lag bytes / new errors | Largest publisher slot lag and total new apply/sync errors in five minutes. Zero lag is not proof that rows are equal. |

The fleet view requires about five minutes of complete, stable readings
before it can show `READY`. New profiles may show `UNKNOWN` during that
window. Saved profiles without fresh observations stay visible as `UNKNOWN`.
If an expected row is absent, check the pgwatch registry and inventory sync
service; the dashboard never guesses instance identity from hostnames.

### What each cutover status means

| Status | Meaning and next step |
| --- | --- |
| `READY` | Replication checks pass, lag and new errors are zero, tables are ready, and the latest data comparison passed. Confirm that comparison is from this cutover. |
| `WARNING` | Lag remains, one to five new errors occurred, or error counters reset. Review the detail panels and wait for stable readings. |
| `NOT READY` | A slot, worker, or table check fails; more than five new errors occurred; or the fleet view sees a failed data check after other checks pass. Find the failing component before cutover. |
| `DATA CHECK REQUIRED` | No exact comparison is recorded for this pair. Arrange the write pause and run the validator at cutover. |
| `DATA CHECK FAILED` | The latest comparison did not pass. This label is on the detail dashboard; the fleet view uses `NOT READY` once other checks pass. Inspect the private validation report. |
| `UNKNOWN` | Required readings are missing, old, or too new to judge. Check collection and profile pairing. |

The database table and Fleet use the same five-minute readiness query. The
detail **Cutover status** panel uses the latest readings, so treat the table's
result as the stronger readiness signal. A high-priority condition can hide
another issue behind one displayed status: inspect the counts and panels.

## Read the detail dashboard

Start with the **Database migrations in this instance pair** table. It shows
source and target database, subscription, slot, health, cutover state, lag,
errors, table readiness, and data-check result. Click a source database to
load its detailed panels. You can also use the visible **Source**, **Target**,
and **Slot** selectors. Slot lists subscriptions on the selected target; an
unrelated publisher slot will not appear. The dashboard resolves
the subscription from the chosen target and slot. Check the **Source** and
**Target** identity tables for database, instance, endpoint, and PostgreSQL
version before interpreting other panels. Each panel's information icon
contains a short definition.

### Publisher panels

| Panel | What to look for |
| --- | --- |
| Replication health | `HEALTHY` means current slot, worker, table, lag, and error checks pass. `WARNING` means lag or a few new errors; `CRITICAL` means a required component fails or errors exceed five; `UNKNOWN` means readings are missing or stale. |
| Slot active | `ACTIVE` means the logical slot has a consumer. Inspect the slot table for connection and WAL state. |
| Data flow | `FLOWING` means confirmed flush LSN changed in 60 seconds; `IDLE` means it did not; `DISCONNECTED` means inactive or not streaming; `UNKNOWN` means insufficient recent samples. `IDLE` can be normal without writes. |
| Lag (bytes) | `pg_current_wal_lsn() - confirmed_flush_lsn` on the publisher, measured in bytes. This is slot backlog, not elapsed time or changed rows. |
| Retained WAL bytes over time | WAL retained since the slot's restart LSN. Sustained growth can threaten publisher disk space. |
| Publication status | Publications named by the subscription, whether each exists on this publisher, and their table counts and publish settings. |
| Logical replication slots | Latest activity, replication connection, LSNs, lag, retained WAL, WAL status, and invalidation reason. |
| Source database size | Size context only; it is not a data-equality test. |

### Subscriber panels

| Panel | What to look for |
| --- | --- |
| Subscription status / Apply worker count | `RUNNING` and at least one apply worker are expected for an enabled subscription. Investigate `DISABLED` or `NO APPLY WORKER`. |
| Table sync worker count | Active initial table-copy workers. Zero is normal after all tables become ready. |
| Last replication message age | Seconds since the apply worker last received a message. Investigate a sustained value over 60 seconds with the slot and worker panels. |
| Apply error count / Sync error count | Cumulative counters. A rising line is a new failure; a flat nonzero number may be old. Status uses increases over five minutes. |
| Table readiness / Table status | Ready/non-ready counts and each table's latest state. `INITIALIZE`, `DATA COPY`, `FINISHED COPY`, and `SYNCHRONIZED` are not yet `READY`. |
| Subscription workers | Worker type, process ID, relation, LSNs, and message times. Distinguish a missing apply worker from an ongoing table copy. |
| Replication origins | Subscriber progress positions. The active flag is inferred from subscription workers, not a PostgreSQL origin-active flag. |
| Target database size | Size context only; a size difference does not prove a row mismatch. |

Snapshot tables show only observations from the last five minutes. Health
queries consider observations older than 90 seconds stale. Time-series
panels follow Grafana's chosen time range: an old line does not mean
collection is still running.

## Troubleshoot by symptom

First recheck **Source**, **Target**, **Slot**, and the identity tables.
Then use the matching row:

| Symptom | Check | Safe next step |
| --- | --- | --- |
| Empty fleet row, selector, or `UNKNOWN` | Enabled profiles; explicit `provider`, `instance`, `migration_role`, and matching `migration_pair` tags; recent samples; inventory sync. | Run `sudo ./scripts/validate.sh`, test connections in the pgwatch Web UI, and inspect `inventory-sync` and pgwatch logs. Wait five minutes after new profiles. |
| Inactive slot or `DISCONNECTED` | Slot active/state, WAL status, invalidation reason; subscription and worker state. | Check network, authentication, SSL, and subscriber logs with the database owner. An invalidated slot needs coordinated recovery. |
| `IDLE` data flow | Lag, slot state, apply worker, and whether the application has written anything. | If lag is zero and there are no writes, no action is needed. If lag grows, investigate subscriber throughput and connectivity. |
| Lag or retained WAL grows | Slot restart/confirmed LSNs, message age, workers, and subscriber logs. | Diagnose subscriber slowdown or disconnection; tell the publisher owner if WAL retention threatens disk space. |
| Disabled subscription or no apply worker | Subscription workers, message age, error counters, and subscriber logs. | Ask the subscriber owner to fix the underlying worker or configuration issue. |
| New apply/sync errors | Which counter rose and when; worker state; subscriber logs. | Diagnose the error with the database owner, then watch for a stable interval with no new errors. A counter reset is not proof of recovery. |
| Publication `MISSING` or tables not ready | Source/target selection, publication name, table list, table status, sync workers. | Correct profile pairing first. Coordinate real publication or sync repair with the database owner; long copies can take time. |
| `DATA CHECK REQUIRED` or `DATA CHECK FAILED` | Validation time and the owner-only report in `validation-reports/`. | Follow the cutover validation procedure below. For failures, inspect reported tables, keys, and changed columns. |
| `db query error` | Grafana panel error, internal metrics database, and Grafana logs. | Run validation and inspect provisioning/logs. A panel SQL failure is not proof replication failed. |

All eight suggested alert rules are provisioned **paused** with no contact
point. Colored panels do not send notifications until the relevant rules
and routing are enabled.

From the monitoring host, use these checks:

~~~bash
sudo ./scripts/validate.sh
sudo docker compose --env-file .env ps
sudo docker compose --env-file .env logs --since=10m pgwatch
sudo docker compose --env-file .env logs --since=10m grafana
~~~

Logs can contain connection details. Keep them out of public tickets. For
passfile, certificate, role, and Web UI problems, follow the
[README troubleshooting section](README.md#troubleshoot-the-web-ui-or-missing-metrics).
This monitoring project does not change slots, subscriptions, publications,
or the source and target databases.

## Before an actual cutover

1. Confirm the intended pair and slot. Require a fresh fleet `READY`, then
   review message age, retained WAL, slot WAL/invalidation state, publication
   membership, and table status in the detail view.
2. Coordinate an application write pause and drain writes. Run the
   [exact data validation procedure](README.md#compare-source-and-target-data-at-cutover)
   for this pair; it is not a routine health probe.
3. Read the new report and `validated_at` time. A saved `PASS` has no
   automatic expiry. Rerun validation at the actual cutover if writes
   resumed or the earlier comparison is no longer representative.
4. Audit DDL, sequences, large objects, and any publication row filters,
   column lists, or keyless tables separately. The validator does not
   cover them.

Replication readiness and row equality are separate checks. Ownership
transfer still follows the normal application and database cutover process.
