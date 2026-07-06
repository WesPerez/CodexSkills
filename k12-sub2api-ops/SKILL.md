---
name: k12-sub2api-ops
description: Prepare, validate, convert, document, and import K12 OpenAI OAuth account bundles for Sub2API, with format-aware duplicate handling. Use when the user mentions K12 accounts, CPA/CliProxyAPI JSON files, Codex auth JSON, Sub2API account import, LINUX DO K12 packages, "do not refresh token" bundles, shuffled/small-batch K12 imports, same-email/different-account packages, or asks for a ready-to-run server-side K12/Sub2API plan.
---

# K12 Sub2API Ops

## Core Rule

Treat K12 account files as sensitive credentials. Do not print tokens, do not publish bundles, do not read browser cookies/localStorage, do not batch refresh tokens, and do not import into a live Sub2API instance unless the user has clearly authorized the import path and supplied or confirmed admin auth.

## Required Reading

For any real K12/Sub2API task, read `references/k12_sub2api_workflow.md` before deciding or editing.

Read `references/account_formats.md` when classifying input files or converting CPA/Codex JSON.

Read `references/sub2api_contract.md` when importing, writing server instructions, or debugging Sub2API API calls.

If the task requires reading LINUX DO bookmarks, topics, floors, replies, or attachments, also use `$linux-do-research`; this skill handles K12/Sub2API decisions, not forum navigation.

## Workflow

1. Inventory source files without exposing secrets:
   - list zip entries and JSON keys;
   - count accounts;
   - redact token values;
   - record source paths and sizes.
2. Classify each source:
   - Sub2API bundle JSON: top-level `accounts`;
   - CPA single-account JSON: top-level `access_token`, `email`, `id_token`, `expired`;
   - zip of many CPA JSON files;
   - zip of grouped Sub2API bundles such as high/mid/full/low groups.
3. Convert to Sub2API bundle shape when needed.
4. Handle duplicates by source format:
   - for CPA single-account zip files, keep every JSON entry by default because the same email can map to different `account_id` values;
   - deduplicate only when explicitly requested or when the same email and same account id/token are confirmed duplicates;
   - for grouped bundle zips, deduplicate cautiously using the rules in `references/account_formats.md`.
5. Validate every generated bundle:
   - `accounts` exists and is a list;
   - `platform=openai`;
   - `type=oauth`;
   - `credentials.plan_type=k12`;
   - `missing_access_token=0`;
   - unique email and unique account-id counts are reported, and any repeated emails are explained rather than blindly removed.
6. Prefer staged import:
   - recommended/high-confidence bundle first;
   - test a small number of accounts;
   - import newer or lower-confidence packages only after the first import works;
   - for volatile public packages, use shuffled small batches.
7. If the user asks to replace old accounts or "only use this batch", remove old generated bundle files from the kit, update `run_on_server.sh`/docs to default to the current batch, and keep source downloads unless explicitly told to delete them.
8. Document exactly what is safe for a server-side Codex to run.

## Reusable Scripts

Use bundled scripts by copying them into the working kit or running them from the skill path.

- `scripts/build_cpa_bundle.py`: convert one or more CPA single-account zip files into a Sub2API bundle.
- `scripts/build_k12_bundle.py`: combine grouped K12 bundle zip entries into recommended/all Sub2API bundles; adjust group names if the source package differs.
- `scripts/import_sub2api_bundle.py`: preview/import a Sub2API bundle through the Sub2API admin API.

Always run preview mode before `--execute`.

## Deliverable Checklist

Include these files in a ready-to-run kit when possible:

- `data/*.json` Sub2API bundles;
- manifest JSON with sources, counts, duplicates, and warnings;
- `scripts/import_sub2api_bundle.py`;
- rebuild scripts for source formats used;
- `run_on_server.sh` or equivalent server command wrapper;
- `README.md`;
- `SERVER_CODEX_PROMPT.md`.

## Reporting

Report source coverage, generated files, account counts, missing-token counts, overlap/duplicate handling, validation commands, imports actually executed, downloaded files, config changes, running processes, and cleanup decisions.
