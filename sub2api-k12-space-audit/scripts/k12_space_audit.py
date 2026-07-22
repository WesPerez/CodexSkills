#!/usr/bin/env python3
"""Read-only Sub2API K12 space availability audit."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from typing import Iterable


SPACE_RE = re.compile(r"^[0-9a-fA-F-]{1,64}$")
CONTAINER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
PG_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
SCHEMA_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")
STATEMENT_TIMEOUT_MS = 15_000
PROCESS_TIMEOUT_SECONDS = 30


LOCAL_AVAILABLE_EXPR = """
(
  deleted_at is null
  and status = 'active'
  and schedulable is true
  and (temp_unschedulable_until is null or temp_unschedulable_until <= now())
  and (expires_at is null or expires_at > now())
  and case
    when credential_expires_at ~ '^[0-9]+$'
      then to_timestamp(credential_expires_at::bigint) > now()
    else true
  end
) as local_available
"""


BASE_CTE = f"""
with k as (
  select
    a.id,
    a.name,
    a.credentials->>'chatgpt_account_id' as space_id,
    a.deleted_at,
    a.status,
    a.schedulable,
    a.temp_unschedulable_until,
    a.expires_at,
    a.credentials->>'expires_at' as credential_expires_at,
    a.credentials->>'email' as email,
    a.error_message,
    a.last_used_at,
    a.extra->>'codex_usage_updated_at' as codex_usage_updated_at
  from accounts a
  where a.platform = 'openai'
    and a.type = 'oauth'
    and a.credentials->>'plan_type' = 'k12'
    and nullif(a.credentials->>'chatgpt_account_id', '') is not null
),
flags as (
  select *, {LOCAL_AVAILABLE_EXPR}
  from k
)
"""


def validate_space(value: str, label: str) -> str:
    value = value.strip()
    if not SPACE_RE.match(value):
        raise SystemExit(f"invalid {label}: expected hex/dash prefix or UUID-like value")
    return value


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def validate_name(value: str, pattern: re.Pattern[str], label: str) -> str:
    if not pattern.fullmatch(value):
        raise argparse.ArgumentTypeError(f"invalid {label}: unsupported name format")
    return value


def validate_limit(value: str) -> int:
    parsed = int(value)
    if not 1 <= parsed <= 1000:
        raise argparse.ArgumentTypeError("limit must be between 1 and 1000")
    return parsed


def sql_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def read_only_envelope(args: argparse.Namespace, query: str) -> str:
    return f"""
begin transaction read only;
set local statement_timeout = '{STATEMENT_TIMEOUT_MS}ms';
set local lock_timeout = '2000ms';
set local search_path = {sql_identifier(args.pg_schema)}, pg_catalog;
{query.strip()}
rollback;
"""


def run_psql(args: argparse.Namespace, query: str) -> str:
    sys.stderr.write(
        "target "
        f"environment={args.environment} container={args.postgres_container} "
        f"database={args.pg_db} schema={args.pg_schema} mode=read-only\n"
    )
    cmd = [
        "docker",
        "exec",
        "-i",
        args.postgres_container,
        "psql",
        "-X",
        "-q",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        args.pg_user,
        "-d",
        args.pg_db,
        "-P",
        "pager=off",
        "-F",
        "\t",
        "-At",
    ]
    try:
        proc = subprocess.run(
            cmd,
            input=read_only_envelope(args, query),
            text=True,
            capture_output=True,
            timeout=PROCESS_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SystemExit("psql command timed out") from exc
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout.rstrip("\n")


def print_tsv(header: Iterable[str], body: str) -> None:
    print("\t".join(header))
    if body:
        print(body)


def query_summary() -> str:
    return f"""
{BASE_CTE}
select
  count(*) as k12_rows,
  count(distinct space_id) as spaces,
  count(*) filter (where deleted_at is null) as active_rows,
  count(*) filter (where local_available) as local_available_accounts,
  count(distinct space_id) filter (where local_available) as spaces_with_local_available,
  count(*) filter (where deleted_at is not null) as deleted_rows,
  count(distinct space_id) filter (where deleted_at is not null) as spaces_with_deleted
from flags;
"""


def query_spaces() -> str:
    return f"""
{BASE_CTE}
select
  space_id,
  count(*) filter (where local_available) as local_available,
  count(*) filter (where deleted_at is null) as active_rows,
  count(*) filter (where deleted_at is not null) as deleted_rows,
  count(*) filter (where deleted_at is not null and error_message ilike '%401%') as deleted_401,
  count(*) filter (where deleted_at is not null and error_message ilike '%402%') as deleted_402,
  count(*) filter (where deleted_at is not null and (error_message is null or btrim(error_message) = '')) as deleted_no_error
from flags
group by space_id
order by local_available desc, active_rows desc, deleted_rows desc, space_id;
"""


def where_space(args: argparse.Namespace) -> str:
    if args.space_id:
        value = validate_space(args.space_id, "space-id")
        return f"space_id = {sql_literal(value)}"
    value = validate_space(args.space_prefix, "space-prefix")
    return f"lower(space_id) like lower({sql_literal(value + '%')})"


def query_space(args: argparse.Namespace) -> str:
    return f"""
{BASE_CTE}
select
  space_id,
  count(*) filter (where local_available) as local_available,
  count(*) filter (where deleted_at is null) as active_rows,
  count(*) filter (where deleted_at is not null) as deleted_rows,
  count(*) filter (where deleted_at is not null and error_message ilike '%401%') as deleted_401,
  count(*) filter (where deleted_at is not null and error_message ilike '%402%') as deleted_402,
  count(*) filter (where deleted_at is not null and (error_message is null or btrim(error_message) = '')) as deleted_no_error
from flags
where {where_space(args)}
group by space_id
order by space_id;
"""


def query_active_accounts(args: argparse.Namespace) -> str:
    return f"""
{BASE_CTE},
active as (
  select f.*
  from flags f
  where f.deleted_at is null
    and {where_space(args)}
)
select
  count(*) over () as matching_active_rows,
  a.id,
  regexp_replace(a.name, E'[\\t\\r\\n]+', ' ', 'g') as name,
  case
    when nullif(a.email, '') is null then '<no_email>'
    when a.email ~ '^[^@]+@[^@]+$'
      then left(a.email, 1) || '***@' || split_part(a.email, '@', 2)
    else '<redacted>'
  end as email_masked,
  a.status,
  a.schedulable,
  coalesce(
    string_agg(regexp_replace(g.name, E'[\\t\\r\\n]+', ' ', 'g'), ',' order by g.name),
    '<no_group>'
  ) as groups,
  coalesce(to_char(a.last_used_at, 'YYYY-MM-DD HH24:MI:SSOF'), '<never>') as last_used_at,
  coalesce(a.codex_usage_updated_at, '<none>') as codex_usage_updated_at,
  case
    when a.error_message is null or btrim(a.error_message) = '' then 'none'
    when a.error_message ilike '%401%' and a.error_message ilike '%402%' then '401+402'
    when a.error_message ilike '%401%' then '401'
    when a.error_message ilike '%402%' then '402'
    else 'other'
  end as error_class
from active a
left join account_groups ag on ag.account_id = a.id
left join groups g on g.id = ag.group_id and g.deleted_at is null
group by a.id, a.name, a.email, a.status, a.schedulable, a.last_used_at, a.codex_usage_updated_at, a.error_message
order by a.id
limit {args.limit};
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--environment",
        required=True,
        choices=["local", "development", "test", "preproduction", "production"],
        help="verified target environment",
    )
    parser.add_argument(
        "--postgres-container",
        required=True,
        type=lambda value: validate_name(value, CONTAINER_RE, "postgres-container"),
    )
    parser.add_argument(
        "--pg-user",
        required=True,
        type=lambda value: validate_name(value, PG_NAME_RE, "pg-user"),
    )
    parser.add_argument(
        "--pg-db",
        required=True,
        type=lambda value: validate_name(value, PG_NAME_RE, "pg-db"),
    )
    parser.add_argument(
        "--pg-schema",
        required=True,
        type=lambda value: validate_name(value, SCHEMA_RE, "pg-schema"),
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("summary")
    sub.add_parser("spaces")
    for name in ("space", "active-accounts"):
        p = sub.add_parser(name)
        group = p.add_mutually_exclusive_group(required=True)
        group.add_argument("--space-id")
        group.add_argument("--space-prefix")
        if name == "active-accounts":
            p.add_argument("--limit", type=validate_limit, default=200)

    args = parser.parse_args()
    if args.command == "summary":
        print_tsv(
            [
                "k12_rows",
                "spaces",
                "active_rows",
                "local_available_accounts",
                "spaces_with_local_available",
                "deleted_rows",
                "spaces_with_deleted",
            ],
            run_psql(args, query_summary()),
        )
    elif args.command == "spaces":
        print_tsv(
            [
                "space_id",
                "local_available",
                "active_rows",
                "deleted_rows",
                "deleted_401",
                "deleted_402",
                "deleted_no_error",
            ],
            run_psql(args, query_spaces()),
        )
    elif args.command == "space":
        print_tsv(
            [
                "space_id",
                "local_available",
                "active_rows",
                "deleted_rows",
                "deleted_401",
                "deleted_402",
                "deleted_no_error",
            ],
            run_psql(args, query_space(args)),
        )
    elif args.command == "active-accounts":
        print_tsv(
            [
                "matching_active_rows",
                "id",
                "name",
                "email_masked",
                "status",
                "schedulable",
                "groups",
                "last_used_at",
                "codex_usage_updated_at",
                "error_class",
            ],
            run_psql(args, query_active_accounts(args)),
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
