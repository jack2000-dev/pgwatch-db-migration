#!/usr/bin/env python3
"""Exact, read-only comparison of full tables in one logical publication."""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Callable, Iterable, Iterator, TextIO


class ValidationError(Exception):
    pass


@dataclass(frozen=True)
class Database:
    label: str
    host: str
    port: str
    name: str
    user: str
    passfile: str
    sslmode: str
    ca: str | None

    @classmethod
    def from_env(cls, prefix: str, label: str) -> "Database":
        return cls(
            label=label,
            host=os.environ[f"{prefix}_DB_HOST"],
            port=os.environ[f"{prefix}_DB_PORT"],
            name=os.environ[f"{prefix}_DB_NAME"],
            user=os.environ[f"{prefix}_VALIDATION_DB_USER"],
            passfile=os.environ["DB_PGPASSFILE_HOST"],
            sslmode=os.getenv(f"{prefix}_DB_SSLMODE", "verify-full"),
            ca=os.getenv(f"{prefix}_DB_SSLROOTCERT_HOST") or None,
        )

    def environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("PGPASSWORD", None)
        env.pop("PGSSLROOTCERT", None)
        env.update(
            PGPASSFILE=self.passfile,
            PGSSLMODE=self.sslmode,
            PGAPPNAME=f"migration-data-validator-{self.label}",
            PGCONNECT_TIMEOUT="10",
            PGOPTIONS=(
                "-c default_transaction_read_only=on -c statement_timeout=0 "
                "-c lock_timeout=5s -c idle_in_transaction_session_timeout=0 "
                "-c TimeZone=UTC -c DateStyle=ISO,YMD -c IntervalStyle=postgres "
                "-c bytea_output=hex -c extra_float_digits=3"
            ),
        )
        if self.sslmode in {"verify-ca", "verify-full"} and self.ca:
            env["PGSSLROOTCERT"] = self.ca
        return env

    def command(self, *extra: str) -> list[str]:
        return [
            "psql", "-X", "--no-psqlrc", "-qAt", "-v", "ON_ERROR_STOP=1",
            "-h", self.host, "-p", self.port, "-d", self.name, "-U", self.user,
            *extra,
        ]

    def run(self, sql: str, **variables: str) -> str:
        command = self.command()
        for name, value in variables.items():
            command.extend(("-v", f"{name}={value}"))
        command.extend(("-c", sql))
        result = subprocess.run(
            command,
            env=self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            detail = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "psql failed"
            raise ValidationError(f"{self.label}: {detail}")
        return result.stdout.strip()


SOURCE_TABLES_SQL = r"""
SELECT json_build_object(
    'schema', pt.schemaname,
    'table', pt.tablename,
    'rowfilter', pt.rowfilter,
    'published_columns', pt.attnames,
    'columns', COALESCE((
        SELECT json_agg(json_build_object(
            'name', a.attname,
            'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
            'not_null', a.attnotnull,
            'identity', a.attidentity,
            'generated', a.attgenerated
        ) ORDER BY a.attnum)
        FROM pg_catalog.pg_attribute AS a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    ), '[]'::json),
    'primary_key', COALESCE((
        SELECT json_agg(a.attname ORDER BY k.ordinality)
        FROM pg_catalog.pg_index AS i
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinality)
        JOIN pg_catalog.pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indrelid = c.oid AND i.indisprimary
    ), '[]'::json),
    'can_select', has_table_privilege(current_user, c.oid, 'SELECT'),
    'schema_usage', has_schema_privilege(current_user, n.oid, 'USAGE')
)::text
FROM pg_catalog.pg_publication_tables AS pt
JOIN pg_catalog.pg_namespace AS n ON n.nspname = pt.schemaname
JOIN pg_catalog.pg_class AS c ON c.relnamespace = n.oid AND c.relname = pt.tablename
WHERE pt.pubname = :'publication'
ORDER BY pt.schemaname, pt.tablename
"""


TARGET_TABLES_SQL = r"""
WITH wanted AS (
    SELECT * FROM json_to_recordset(:'tables'::json)
      AS x(schema_name text, table_name text)
), selected_subscription AS (
    SELECT oid FROM pg_catalog.pg_subscription
    WHERE subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database())
      AND subname = :'subscription'
)
SELECT json_build_object(
    'schema', w.schema_name,
    'table', w.table_name,
    'exists', c.oid IS NOT NULL,
    'columns', COALESCE((
        SELECT json_agg(json_build_object(
            'name', a.attname,
            'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
            'not_null', a.attnotnull,
            'identity', a.attidentity,
            'generated', a.attgenerated
        ) ORDER BY a.attnum)
        FROM pg_catalog.pg_attribute AS a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    ), '[]'::json),
    'primary_key', COALESCE((
        SELECT json_agg(a.attname ORDER BY k.ordinality)
        FROM pg_catalog.pg_index AS i
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinality)
        JOIN pg_catalog.pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indrelid = c.oid AND i.indisprimary
    ), '[]'::json),
    'can_select', CASE WHEN c.oid IS NULL THEN false ELSE has_table_privilege(current_user, c.oid, 'SELECT') END,
    'schema_usage', CASE WHEN n.oid IS NULL THEN false ELSE has_schema_privilege(current_user, n.oid, 'USAGE') END,
    'sync_state', (
        SELECT r.srsubstate::text
        FROM pg_catalog.pg_subscription_rel AS r, selected_subscription AS s
        WHERE r.srsubid = s.oid AND r.srrelid = c.oid
    )
)::text
FROM wanted AS w
LEFT JOIN pg_catalog.pg_namespace AS n ON n.nspname = w.schema_name
LEFT JOIN pg_catalog.pg_class AS c ON c.relnamespace = n.oid AND c.relname = w.table_name
ORDER BY w.schema_name, w.table_name
"""


SUBSCRIPTION_SQL = r"""
SELECT json_build_object(
    'enabled', subenabled,
    'publications', subpublications,
    'slot', subslotname
)::text
FROM pg_catalog.pg_subscription
WHERE subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database())
  AND subname = :'subscription'
"""


CATCHUP_SQL = r"""
SELECT COALESCE(o.remote_lsn, '0/0'::pg_lsn) >= :'cutoff'::pg_lsn
FROM pg_catalog.pg_subscription AS s
LEFT JOIN pg_catalog.pg_replication_origin_status AS o
  ON o.external_id = 'pg_' || s.oid::text
WHERE s.subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database())
  AND s.subname = :'subscription'
"""


def parse_json_lines(output: str) -> list[dict]:
    return [json.loads(line) for line in output.splitlines() if line]


def normalized_columns(table: dict) -> dict[str, dict]:
    return {column["name"]: column for column in table["columns"]}


def preflight(source: Database, target: Database, publication: str, subscription: str) -> list[dict]:
    exists = source.run(
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname = :'publication')",
        publication=publication,
    )
    if exists != "t":
        raise ValidationError(f"source publication {publication!r} does not exist")

    tables = parse_json_lines(source.run(SOURCE_TABLES_SQL, publication=publication))
    if not tables:
        raise ValidationError(f"source publication {publication!r} contains no tables")

    sub_rows = parse_json_lines(target.run(SUBSCRIPTION_SQL, subscription=subscription))
    if len(sub_rows) != 1:
        raise ValidationError(f"target subscription {subscription!r} does not exist")
    sub = sub_rows[0]
    if not sub["enabled"]:
        raise ValidationError(f"target subscription {subscription!r} is disabled")
    if publication not in sub["publications"]:
        raise ValidationError(
            f"target subscription {subscription!r} does not subscribe to {publication!r}"
        )

    wanted = json.dumps(
        [{"schema_name": table["schema"], "table_name": table["table"]} for table in tables],
        separators=(",", ":"),
    )
    target_rows = parse_json_lines(
        target.run(TARGET_TABLES_SQL, tables=wanted, subscription=subscription)
    )
    target_by_name = {(row["schema"], row["table"]): row for row in target_rows}

    problems: list[str] = []
    for table in tables:
        name = (table["schema"], table["table"])
        display = f"{name[0]}.{name[1]}"
        all_columns = [column["name"] for column in table["columns"]]
        if table["rowfilter"] is not None:
            problems.append(f"{display}: row filters are not supported")
        if set(table["published_columns"]) != set(all_columns):
            problems.append(f"{display}: publication does not include every column")
        if not table["primary_key"]:
            problems.append(f"{display}: primary key is required")
        if not table["can_select"] or not table["schema_usage"]:
            problems.append(f"{display}: source validation role lacks USAGE/SELECT")

        peer = target_by_name.get(name)
        if not peer or not peer["exists"]:
            problems.append(f"{display}: target table is missing")
            continue
        if normalized_columns(peer) != normalized_columns(table):
            problems.append(f"{display}: source and target column definitions differ")
        if peer["primary_key"] != table["primary_key"]:
            problems.append(f"{display}: source and target primary keys differ")
        if not peer["can_select"] or not peer["schema_usage"]:
            problems.append(f"{display}: target validation role lacks USAGE/SELECT")
        if peer["sync_state"] != "r":
            problems.append(f"{display}: target subscription table state is not ready")

    if problems:
        raise ValidationError("preflight failed:\n  - " + "\n  - ".join(problems))
    return tables


class SnapshotKeeper:
    def __init__(self, database: Database, include_lsn: bool = False):
        self.database = database
        self.stderr = tempfile.TemporaryFile(mode="w+t", encoding="utf-8")
        self.process = subprocess.Popen(
            ["stdbuf", "-oL", *database.command()],
            env=database.environment(),
            text=True,
            bufsize=1,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
        )
        assert self.process.stdin is not None and self.process.stdout is not None
        try:
            statements = [
                "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;",
                "SELECT 'SNAPSHOT:' || pg_catalog.pg_export_snapshot();",
            ]
            if include_lsn:
                statements.append("SELECT 'LSN:' || pg_catalog.pg_current_wal_lsn();")
            self.process.stdin.write("\n".join(statements) + "\n")
            self.process.stdin.flush()
            self.snapshot = self._read_marker("SNAPSHOT:")
            self.cutoff_lsn = self._read_marker("LSN:") if include_lsn else None
        except Exception:
            self.close()
            raise

    def _read_marker(self, prefix: str) -> str:
        assert self.process.stdout is not None
        while True:
            line = self.process.stdout.readline()
            if line.startswith(prefix):
                return line.removeprefix(prefix).strip()
            if line == "" and self.process.poll() is not None:
                self.stderr.seek(0)
                detail = self.stderr.read().strip().splitlines()
                raise ValidationError(
                    f"{self.database.label}: " + (detail[-1] if detail else "snapshot session failed")
                )

    def close(self) -> None:
        if self.process.poll() is None and self.process.stdin is not None:
            try:
                self.process.stdin.write("ROLLBACK;\n\\q\n")
                self.process.stdin.flush()
                self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.stderr.close()


def wait_for_catchup(target: Database, subscription: str, cutoff: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while True:
        if target.run(CATCHUP_SQL, subscription=subscription, cutoff=cutoff) == "t":
            return
        if time.monotonic() >= deadline:
            raise ValidationError(
                f"target subscription did not reach source LSN {cutoff} within {timeout} seconds"
            )
        time.sleep(1)


def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def row_sql(table: dict, snapshot: str) -> str:
    relation = f'{quote_ident(table["schema"])}.{quote_ident(table["table"])}'
    key_parts: list[str] = []
    for column in table["primary_key"]:
        key_parts.extend((quote_literal(column), f"t.{quote_ident(column)}::text"))
    key = "jsonb_build_object(" + ", ".join(key_parts) + ")::text"
    return f"""
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT {quote_literal(snapshot)};
COPY (
    SELECT key_text, row_text
    FROM (
        SELECT {key} AS key_text, to_jsonb(t)::text AS row_text
        FROM {relation} AS t
    ) AS rows
    ORDER BY key_text COLLATE "C"
) TO STDOUT WITH (FORMAT csv, ENCODING 'UTF8');
COMMIT;
"""


class RowStream(Iterator[tuple[str, str]]):
    def __init__(self, database: Database, sql: str):
        self.database = database
        self.stderr = tempfile.TemporaryFile(mode="w+t", encoding="utf-8")
        self.process = subprocess.Popen(
            ["stdbuf", "-oL", *database.command("-c", sql)],
            env=database.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
        )
        assert self.process.stdout is not None
        self.reader = csv.reader(self.process.stdout)

    def __iter__(self) -> "RowStream":
        return self

    def __next__(self) -> tuple[str, str]:
        try:
            row = next(self.reader)
        except StopIteration:
            code = self.process.wait()
            if code:
                self.stderr.seek(0)
                detail = self.stderr.read().strip().splitlines()
                raise ValidationError(
                    f"{self.database.label}: " + (detail[-1] if detail else "row stream failed")
                )
            raise
        if len(row) != 2:
            raise ValidationError(f"{self.database.label}: invalid row stream")
        return row[0], row[1]

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.stderr.close()


def json_value(value: str):
    return json.loads(value, parse_float=Decimal)


def compare_streams(
    source_rows: Iterable[tuple[str, str]],
    target_rows: Iterable[tuple[str, str]],
    table_name: str,
    emit: Callable[[dict], None],
) -> dict[str, int]:
    source = iter(source_rows)
    target = iter(target_rows)
    source_row = next(source, None)
    target_row = next(target, None)
    counts = {"source": 0, "target": 0, "missing": 0, "extra": 0, "changed": 0}

    while source_row is not None or target_row is not None:
        if target_row is None or (source_row is not None and source_row[0] < target_row[0]):
            counts["source"] += 1
            counts["missing"] += 1
            emit({
                "record": "difference", "type": "missing_target", "table": table_name,
                "key": json.loads(source_row[0]),
            })
            source_row = next(source, None)
            continue
        if source_row is None or target_row[0] < source_row[0]:
            counts["target"] += 1
            counts["extra"] += 1
            emit({
                "record": "difference", "type": "extra_target", "table": table_name,
                "key": json.loads(target_row[0]),
            })
            target_row = next(target, None)
            continue

        counts["source"] += 1
        counts["target"] += 1
        if source_row[1] != target_row[1]:
            source_value = json_value(source_row[1])
            target_value = json_value(target_row[1])
            columns = sorted(
                name for name in source_value.keys() | target_value.keys()
                if name not in source_value
                or name not in target_value
                or source_value[name] != target_value[name]
            )
            if columns:
                counts["changed"] += 1
                emit({
                    "record": "difference", "type": "changed", "table": table_name,
                    "key": json.loads(source_row[0]), "columns": columns,
                })
        source_row = next(source, None)
        target_row = next(target, None)
    return counts


class Report:
    def __init__(self, path: Path):
        if not path.parent.exists():
            path.parent.mkdir(mode=0o700, parents=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.path = path
        self.file: TextIO = os.fdopen(fd, "w", encoding="utf-8")

    def write(self, record: dict) -> None:
        self.file.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n")

    def close(self) -> None:
        self.file.close()


def default_report_path() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path("validation-reports") / f"data-validation-{stamp}.jsonl"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    try:
        timeout_default = int(os.getenv("VALIDATION_CATCHUP_TIMEOUT_SECONDS", "300"))
    except ValueError:
        parser.error("VALIDATION_CATCHUP_TIMEOUT_SECONDS must be an integer")
    parser.add_argument(
        "--writes-paused", action="store_true",
        help="skip the interactive write-pause confirmation",
    )
    parser.add_argument(
        "--catchup-timeout", type=int, default=timeout_default,
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)
    if args.catchup_timeout < 1:
        parser.error("--catchup-timeout must be positive")
    if not args.writes_paused and not sys.stdin.isatty():
        parser.error(
            "interactive confirmation requires a terminal; "
            "use --writes-paused only after pausing writes"
        )
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    source_snapshot: SnapshotKeeper | None = None
    target_snapshot: SnapshotKeeper | None = None
    report: Report | None = None
    streams: list[RowStream] = []

    try:
        source = Database.from_env("SOURCE", "source")
        target = Database.from_env("TARGET", "target")
        publication = os.environ["SOURCE_PUBLICATION_NAME"]
        subscription = os.environ["TARGET_SUBSCRIPTION_NAME"]
        print("Preflight: publication, subscription, schema, keys, readiness, and privileges")
        tables = preflight(source, target, publication, subscription)
        print(f"PASS: {len(tables)} published table(s) are eligible")

        if not args.writes_paused:
            answer = input("Pause and drain application writes, then type PAUSED: ")
            if answer != "PAUSED":
                raise ValidationError("write-pause confirmation was not provided")

        print("Capturing source snapshot and waiting for subscriber catch-up...")
        source_snapshot = SnapshotKeeper(source, include_lsn=True)
        assert source_snapshot.cutoff_lsn is not None
        wait_for_catchup(
            target, subscription, source_snapshot.cutoff_lsn, args.catchup_timeout
        )
        target_snapshot = SnapshotKeeper(target)
        print("SNAPSHOTS CAPTURED: application writes may now resume.", flush=True)

        report = Report(args.output or default_report_path())
        report.write({
            "record": "header",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "publication": publication,
            "subscription": subscription,
            "cutoff_lsn": source_snapshot.cutoff_lsn,
        })

        totals = {
            "tables": 0, "source": 0, "target": 0,
            "missing": 0, "extra": 0, "changed": 0,
        }
        for table in tables:
            name = f'{table["schema"]}.{table["table"]}'
            source_stream = RowStream(source, row_sql(table, source_snapshot.snapshot))
            target_stream = RowStream(target, row_sql(table, target_snapshot.snapshot))
            streams[:] = [source_stream, target_stream]
            try:
                counts = compare_streams(
                    source_stream, target_stream, name, report.write
                )
            finally:
                source_stream.close()
                target_stream.close()
                streams.clear()
            totals["tables"] += 1
            for key in ("source", "target", "missing", "extra", "changed"):
                totals[key] += counts[key]
            report.write({"record": "table_summary", "table": name, **counts})
            print(
                f'{name}: source={counts["source"]} target={counts["target"]} '
                f'missing={counts["missing"]} extra={counts["extra"]} '
                f'changed={counts["changed"]}'
            )

        differences = totals["missing"] + totals["extra"] + totals["changed"]
        report.write({"record": "summary", **totals, "differences": differences})
        print(f"Report: {report.path}")
        if differences:
            print(f"FAIL: {differences} row difference(s) found", file=sys.stderr)
            return 1
        print("PASS: published table data is equal at the captured cutover point")
        return 0
    except (ValidationError, KeyError, OSError, ValueError, csv.Error) as error:
        if report is not None:
            report.write({"record": "error", "message": "validation incomplete"})
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        if report is not None:
            report.write({"record": "error", "message": "validation interrupted"})
        print("ERROR: validation interrupted", file=sys.stderr)
        return 2
    finally:
        for stream in streams:
            stream.close()
        if target_snapshot is not None:
            target_snapshot.close()
        if source_snapshot is not None:
            source_snapshot.close()
        if report is not None:
            report.close()


if __name__ == "__main__":
    raise SystemExit(main())
