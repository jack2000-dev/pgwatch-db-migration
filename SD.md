# Multi-instance, multi-database monitoring design

Status: proposed. This document does not implement dashboard changes.

## Decision

Yes. Grafana can let an operator select a source instance and target instance,
then monitor every database migration between them.

~~~text
Fleet overview -> Instance-pair overview -> Database-pair detail
~~~

Keep pgwatch and the PostgreSQL metrics sink. For now, use one pgwatch
`postgres` profile per monitored database, add a stable instance identity tag,
and join publisher and subscriber profiles with `migration_pair`. This fits the
current repository without adding another service or registry.

Do not switch immediately to continuous discovery. It discovers databases well,
but one discovered source gives all resolved databases the same custom tags and
metric schedule. That cannot naturally assign a different `migration_pair` to
each database.

## Why the model is database-pair based

PostgreSQL publications are database-scoped. Subscriptions are also attached to
a database and normally consume through one logical replication slot. An
instance with ten migrated databases therefore has ten or more distinct
replication streams, not one instance-wide stream.

~~~mermaid
flowchart LR
    subgraph S[Source instance]
        S1[(orders)]
        S2[(billing)]
        S3[(identity)]
    end
    subgraph T[Target instance]
        T1[(orders)]
        T2[(billing)]
        T3[(identity)]
    end

    S1 -->|publication + slot| T1
    S2 -->|publication + slot| T2
    S3 -->|publication + slot| T3

    S1 -. metrics .-> P[pgwatch]
    S2 -. metrics .-> P
    S3 -. metrics .-> P
    T1 -. metrics .-> P
    T2 -. metrics .-> P
    T3 -. metrics .-> P
    P --> M[(Metrics PostgreSQL)]
    M --> F[Fleet overview]
    F --> I[Instance-pair overview]
    I --> D[Database-pair detail]
~~~

Instance views aggregate database streams for navigation. Database-level state
remains the source of truth.

## Identity model

Do not use a hostname or IP address as identity. Managed endpoints can change
during failover. Use configured tags as identity and show the detected endpoint
only as operational context.

| Field | Scope | Purpose | Example |
|---|---|---|---|
| `instance_id` | PostgreSQL instance | Stable provider/internal identifier | `do:cluster-01` |
| `instance` | PostgreSQL instance | Human-readable display name | `payments-source` |
| `migration_role` | Database profile | `publisher` or `subscriber` | `publisher` |
| `migration_pair` | Source/target database pair | Fleet-wide unique join key | `payments-01-orders` |
| `tag_database` | Database | Actual `current_database()` reported by metrics | `orders` |
| `dbname` | pgwatch profile | Internal metric-series key, not displayed database identity | `do-orders-src` |
| `slot_name` / `subscription` | Replication stream | Identifies a stream within a database pair | `orders_migration_sub` |

Rules:

1. `instance_id` is stable and unique across providers and environments.
2. Both sides of a database pair use the same globally unique
   `migration_pair`.
3. Database names may differ between source and target; never pair by name alone.
4. Profile names may change without changing instance or database identity.
5. Multiple streams in one pair aggregate to the worst stream status.

The current `instance` tag can initially serve as both ID and display name.
Add `instance_id` when duplicate names or provider failovers make that ambiguous.

## Collection strategy

### Recommended now: explicit profiles

Create one `postgres` profile for every publisher database and one for every
subscriber database. Profiles on the same instance reuse endpoint, monitoring
role, passfile, and instance tags. Their database name, role-specific metrics,
and `migration_pair` differ.

Advantages:

- exact per-database pairing;
- different source and target database names are supported;
- unrelated and system databases are excluded;
- metric schedules can differ by migration role;
- it matches the current Web UI workflow.

The cost is approximately two profiles per database pair. Keep this model until
manual profile maintenance or database churn becomes a measured problem.

### Later option: continuous discovery

pgwatch `postgres-continuous-discovery` resolves all permitted databases on one
instance and supports include/exclude patterns. Use it when databases change
frequently and one of these is true:

- source/target pairing follows a safe naming rule;
- all discovered databases share one migration relationship; or
- a small explicit mapping table provides per-database relationships.

Do not run explicit and discovery profiles for the same database. That creates
duplicate series and ambiguous health rows.

### Blocking correction before continuous discovery

The current custom metrics are marked `is_instance_level: true`. pgwatch uses
that flag to cache and share results between databases of a continuous source.
The following metrics query `current_database()` or database-local catalogs and
must be changed to `false` first:

- `general_database`
- `source_replication_slot`
- `source_publication`
- `target_subscription`
- `target_subscription_errors`
- `target_table_sync`
- `target_replication_origins`

`instance_up` can remain instance-level. Without this correction, data collected
from one database could be reused for another database on the same instance.

## Grafana experience

### Dashboard 1: fleet overview

Show one row per instance pair:

| Source instance | Target instance | DB pairs | Healthy | Warning | Critical | Cutover ready | Last sample |
|---|---|---:|---:|---:|---:|---:|---|
| `payments-source` | `payments-target` | 12 | 9 | 1 | 2 | 7 | 10 s ago |

The instance-pair status is the worst child status. Missing or stale expected
databases are `UNKNOWN`, never healthy.

### Dashboard 2: instance-pair overview

Selectors:

~~~text
[Source instance v] [Target instance v] [Database pair: All v]
~~~

Use a table rather than repeated full dashboards:

| Source DB | Target DB | Source size | Target size | Slot / subscription | Lag | Errors (5m) | Tables ready | Health | Data check | Cutover |
|---|---|---:|---:|---|---:|---:|---:|---|---|---|
| `orders` | `orders` | 84 GB | 82 GB | `orders_sub` | 0 B | 0 | 42/42 | HEALTHY | PASS | READY |
| `billing` | `billing_v2` | 31 GB | 30 GB | `billing_sub` | 8 MB | 2 | 18/20 | WARNING | - | NOT READY |

Click a row to open database detail. Grafana supports repeated panels, but
repeating the complete layout for many databases is hard to scan and expensive
to query.

### Dashboard 3: database-pair detail

Reuse the current left/right layout:

~~~text
Source database and instance                 Target database and instance
Replication health                          Cutover status
Slot, publication, WAL and lag              Subscription, errors and table sync
Source database size                        Target database size
~~~

### Variable chain

Use chained Grafana query variables:

~~~text
source_instance
  -> target_instance sharing at least one migration_pair
    -> database_pair within both selected instances
      -> hidden source_profile and target_profile
        -> slot
          -> hidden subscription
~~~

The visible database-pair value is `migration_pair` and its label is
`source_database -> target_database`. Hidden profile values preserve compatibility
with pgwatch's `dbname` metric column.

## Status aggregation

### Health

For each slot/subscription stream:

- `HEALTHY`: metrics are fresh, slot is active and streaming, subscription is
  enabled with an apply worker, lag is zero, no new apply/sync errors occurred,
  and every table is ready.
- `WARNING`: replication is active but lag is nonzero, one to five new errors
  occurred, or an error-counter reset makes the interval uncertain.
- `CRITICAL`: stream or worker is down, more than five new errors occurred, or a
  table is not ready.
- `UNKNOWN`: required metrics are missing or stale.

Database-pair health is the worst stream status. Instance-pair health is the
worst database-pair status. Display child counts beside the aggregate so a
single failed database cannot be hidden by a green average.

### Cutover

`READY` is database-pair scoped and requires:

- health is `HEALTHY`;
- lag and new errors are zero;
- all subscribed tables are ready;
- the latest exact source/target row comparison is `PASS`.

An instance pair is ready only when every expected database pair is ready.
Database-size equality is not a condition: indexes, bloat, and physical layout
can differ even when logical rows are equal.

The validator currently handles one pair configured in `.env`. Run it once per
`migration_pair`. Add a `--pair` option or private batch manifest only when
operators actually need batch validation. Never infer equality from pgwatch
metrics.

## Constraints

| Constraint | Response |
|---|---|
| Logical replication is database-scoped | Aggregate for instance views; retain database detail. |
| Source/target database names may differ | Join with `migration_pair`. |
| Endpoint or IP changes | Select by stable `instance_id` and display endpoint separately. |
| One source database fans out to multiple targets | A single `migration_pair` tag is insufficient; add a relationship table before supporting fan-out. |
| Multiple streams exist in one database pair | Aggregate worst status and expose a stream selector. |
| A database is omitted from configuration | Compare against expected inventory; missing pairs are `UNKNOWN`. |
| Metrics become stale | Keep the 90-second freshness gate and five-minute history requirement. |
| Equality is point-in-time and expensive | Validate near cutover with writes paused; store only status and totals. |
| Monitoring role lacks `CONNECT` | Discovery cannot collect that database; report coverage separately from health. |
| Fleet size multiplies query load | Tune intervals and retention after measuring duration and sink growth. |

## Scale and capacity

At current intervals, one database pair schedules approximately 10 publisher
queries and 16 subscriber queries per minute, excluding retries.
`PW_MAX_PARALLEL_CONNECTIONS_PER_DB=1` limits concurrency per database, not
across the full instance.

`target_table_sync` is likely the largest storage producer because it returns
one row per subscribed table every 30 seconds:

~~~text
approximate rows/minute = 2 x subscribed tables x database pairs
~~~

Also account for one row per logical slot every 10 seconds and one or more rows
per subscription worker every 10 seconds. Before onboarding a large fleet:

1. Measure query duration on the largest database and publication.
2. Measure metrics-database growth over one retention cycle.
3. Increase low-value intervals before adding infrastructure.
4. Keep fast intervals for slot, worker, lag, and errors.
5. Alert on collection coverage so pgwatch failure cannot look healthy.

## Delivery plan

### Phase 1: instance-aware dashboards

1. Add `instance_id` to Web UI profiles and keep `instance` as display name.
2. Add source-instance and target-instance variables.
3. Build the database-pair matrix and link rows to current detail.
4. Aggregate health and cutover with worst-child semantics.
5. Test stale data, duplicate names, and different source/target database names.

### Phase 2: safe multi-database collection

1. Mark database-scoped metrics as non-instance-level.
2. Measure query and sink growth with representative database/table counts.
3. Add coverage counts: expected, configured, fresh, stale, and missing pairs.

### Phase 3: optional automation

Adopt continuous discovery or a relationship registry only when manual profile
maintenance becomes a measured problem. Fan-out, fan-in, or batch validation
are the triggers for an explicit relationship model.

## References

- [pgwatch source types and continuous discovery](https://pgwat.ch/devel/reference/source_types.html)
- [pgwatch collection, concurrency, cache, and retention options](https://pgwat.ch/latest/reference/cli_env.html)
- [pgwatch metric definitions and instance-level caching](https://pgwat.ch/devel/godoc/pkg/github.com/cybertec-postgresql/pgwatch/v5/internal/metrics/)
- [Grafana query variables](https://grafana.com/docs/learning-paths/interactive-dashboards/use-variables-queries/)
- [PostgreSQL 18 publications](https://www.postgresql.org/docs/18/logical-replication-publication.html)
- [PostgreSQL 18 subscriptions](https://www.postgresql.org/docs/18/logical-replication-subscription.html)
