# K12 Space Audit Queries

## Local Availability Predicate

```sql
deleted_at is null
and status = 'active'
and schedulable is true
and (temp_unschedulable_until is null or temp_unschedulable_until <= now())
and (expires_at is null or expires_at > now())
and case
  when (credentials->>'expires_at') ~ '^[0-9]+$'
    then to_timestamp((credentials->>'expires_at')::bigint) > now()
  else true
end
```

Always combine this with:

```sql
platform = 'openai'
and type = 'oauth'
and credentials->>'plan_type' = 'k12'
```

## Summary Columns

- `k12_rows`: all active and soft-deleted K12 OpenAI OAuth rows.
- `spaces`: distinct `credentials.chatgpt_account_id` values.
- `active_rows`: K12 rows with `deleted_at is null`.
- `local_available_accounts`: rows matching the local availability predicate.
- `spaces_with_local_available`: distinct space IDs with at least one local available row.
- `deleted_rows`: K12 rows with `deleted_at is not null`.
- `spaces_with_deleted`: distinct space IDs with at least one deleted row.

## Space Columns

- `space_id`: `credentials->>'chatgpt_account_id'`.
- `local_available`: rows matching the local availability predicate.
- `active_rows`: rows not soft-deleted.
- `deleted_rows`: rows soft-deleted.
- `deleted_401`: deleted rows whose `error_message` contains `401`.
- `deleted_402`: deleted rows whose `error_message` contains `402`.
- `deleted_no_error`: deleted rows with null or blank `error_message`.

## Interpretation

- A space with `deleted_402 > 0` is the strongest database-only signal of workspace/account deactivation.
- A space with `deleted_401 > 0` has account/token failures, but that does not automatically prove the whole space is unusable.
- A space with `deleted_no_error > 0` explains red-dot style local deletion indicators, but it lacks a recorded upstream failure reason.
- A space with `local_available > 0` still has locally schedulable rows unless upstream probes prove otherwise.
- Database-only results can be stale relative to upstream OpenAI/ChatGPT state.

## Active Account Output

`active-accounts` returns the total number of matching non-deleted rows plus a limited list containing account ID/name, masked email, scheduling state, group names, timestamps, and `error_class`. The error class is `none`, `401`, `402`, `401+402`, or `other`; raw `error_message` is intentionally not returned.

## Read-only Envelope

The script requires explicit environment, container, user, database, and schema arguments and writes a credential-free target summary to stderr. The environment label is an operator declaration, not proof that the connection points to that environment. It runs each generated query in `begin transaction read only`, uses an explicit search path, applies statement/lock/process timeouts, ignores local `psql` startup files, and rolls back. These controls do not replace environment identification or production impact review.
