# Agent instructions

This repository is a monitoring-only pgwatch/Grafana stack for PostgreSQL
logical-replication migration pairs:

`publisher → subscriber`

Treat every publisher and subscriber as a production system. The default
agent behavior is read-only inspection, documentation, testing, and safe
monitoring configuration changes.

## Non-negotiable safety rules

- Never run or add SQL that changes a monitored PostgreSQL instance. Allowed
  statements are `SELECT` and harmless metadata reads such as `SHOW`.
- Every direct connection to a monitored database must use a dedicated
  least-privilege monitoring role, `sslmode=verify-full` when available, and
  session safeguards equivalent to:

  ```text
  default_transaction_read_only=on
  statement_timeout=5s
  lock_timeout=1s
  ```

- Do not use a superuser, `REPLICATION`, application credentials, or
  `pg_subscription.subconninfo`. Do not expose passwords, passfiles, or
  connection strings containing secrets in tracked files, logs, or responses.
- Never create, alter, enable, disable, refresh, advance, drop, reset, or
  restart anything on either PostgreSQL instance. This includes databases,
  schemas, tables, publications, subscriptions, replication slots, origins,
  roles, grants, server settings, and statistics.
- Never write application data or use `validate-data.sh` as a routine health
  check. That workflow intentionally requires an application write pause and
  explicit operator coordination.
- Do not delete Docker volumes, metric history, source profiles, or
  monitoring state unless the user explicitly requests that destructive
  operation.

## What this stack monitors

Each migration pair has two pgwatch profiles with the same
`migration_pair` tag:

- Publisher: publication configuration plus the matching logical slot,
  connection state, WAL lag, and retained WAL.
- Subscriber: subscription enabled/apply state, worker and message health,
  apply/sync errors, table synchronization, and replication origins.
- Shared: connectivity and database health. Pairing relies on the matching
  migration pair and slot names; do not silently infer a pair from hostnames.

Use the existing SQL under `sql/` and metrics under `config/metrics/`. Extend
those definitions only when the requested signal cannot be obtained from an
existing metric. Keep custom SQL catalog-only and read-only, and support the
PostgreSQL versions already handled by the repository.

## Cut-over readiness

`lag_bytes = 0` is required but is not sufficient. Report `READY` only when
the pair has fresh, complete observations for at least five stable minutes:

1. The publisher slot is active and streaming for the subscriber.
2. Publisher `lag_bytes` is zero for the whole readiness window. This is WAL
   byte distance, not proof that application rows are equal.
3. The target subscription is enabled, has `subscription_status = 1`, and
   has an apply worker (`apply_worker_count > 0`).
4. All tracked subscription tables are ready:
   `total_tables > 0` and `non_ready_tables = 0`.
5. Apply and sync error counters do not increase, and their statistics reset
   timestamp remains stable. PostgreSQL 18 conflict counters must also be
   reviewed when present.
6. Metrics are not missing or stale: the dashboard treats observations older
   than 90 seconds, incomplete pair data, or a newly started collection window
   as `UNKNOWN`.

Before an actual cut-over, also review the detail dashboard for replication
message age, retained WAL, slot invalidation/conflict state, replication
origin progress, publication/table membership, and any paused alert that would
become relevant. A message older than 60 seconds, growing retained WAL, an
inactive slot, missing apply worker, non-ready table, or any new replication
error blocks cut-over until investigated.

The fleet dashboard intentionally maps states as follows:

- `READY`: all stable-window gates pass.
- `WARNING`: lag is nonzero, errors increased from zero to five, or error
  reset stability is uncertain.
- `NOT READY`: replication/table health fails or more than five new errors
  occur in five minutes.
- `UNKNOWN`: required metrics are missing, stale, incomplete, or too new.

Dashboard readiness is an operational signal, not a data-equality guarantee.
Before transferring application ownership, coordinate the application write
pause and run the separately documented exact data validator. Audit DDL,
sequences, large objects, row filters, and keyless tables separately because
logical replication does not cover all of them.

## Safe operating workflow

1. Read `README.md`, the relevant dashboard query, and the existing metric or
   SQL definition before changing anything.
2. Prefer existing metrics and queries over new abstractions or duplicate
   checks. Keep changes small and preserve the read-only posture.
3. Use `./scripts/validate.sh` for the repository's read-only connectivity,
   SQL, service, dashboard, alert, and fresh-metric checks. Do not bypass its
   connection safeguards with ad-hoc credentials.
4. Treat missing rows from a system view as an observable state to explain,
   not as permission to create or repair replication objects.
5. Run the smallest relevant test after changes, then inspect `git diff` and
   `git diff --check`. Never include `.env`, passfiles, certificates, or real
   endpoints in a commit.

Changes to monitoring dashboards, thresholds, or alerts must not silently
change the definition of `READY`. If a threshold or readiness gate changes,
update the dashboard, tests, and README together and call out the operational
impact.

## Useful references in this repository

- `README.md`: setup, least-privilege roles, profile tags, validation, and
  cut-over procedure.
- `sql/source_replication_slot.sql`: publisher slot and WAL state.
- `sql/target_subscription.sql`: subscriber apply and message state.
- `sql/target_table_sync.sql`: per-table synchronization readiness.
- `grafana/dashboards/logical-replication-overview.json`: fleet readiness
  calculation and its five-minute stability window.
- `scripts/validate.sh`: read-only end-to-end validation.
