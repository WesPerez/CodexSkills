# K12/Sub2API Full Workflow

Use this reference for end-to-end K12 account package handling. It is based on the verified workflow from LINUX DO K12 packages and Sub2API imports.

## Operating Principles

- Optimize for a disabled/non-technical user: produce a kit or prompt that another Codex can run on the server with minimal manual action.
- Be honest about coverage. Do not say "all bookmarks" or "all floors" were read unless coverage was recorded and gaps were closed.
- Treat OAuth account JSON as credentials.
- Redact access tokens, id tokens, refresh tokens, session tokens, cookies, and bearer tokens in logs and final output.
- Do not read browser cookies, localStorage, session storage, or profile files to obtain credentials.
- Do not post to forums, click "refresh token", batch refresh accounts, or mutate remote services without explicit authorization.
- Do not import every package just because it exists. Prefer staged imports and validation.

## Source Intake

For each candidate file or download:

1. Record absolute path, size, modification time, source URL/topic, and any password/notice from the source thread.
2. Inspect zip structure with a structured zip reader.
3. Inspect JSON keys, not token values.
4. Count JSON entries and classify the source format.
5. Identify explicit warnings from the source thread, especially "do not refresh token" or "small/random import" advice.
6. Record whether this source overlaps with existing bundles by email and by account id. Do not treat email overlap alone as proof of a duplicate for CPA single-account zips.

Never rely on file name alone. Verify the inside shape.

## Known Source Lessons

The previously verified package set had these conclusions:

- `1334个-不要去刷新令牌.zip` was the best initial source.
- Password/notice from its source thread included `密1122` and "不要刷新令牌".
- The 1022 CPA package overlapped with the 1334 package and should not be imported together initially.
- Outlook workspace creation was unreliable/dead, but downloaded OAuth credentials could still be importable.
- One newer second batch topic `2527525` contained two 100-account CPA zip files:
  - `kxj_k12_batch_001_100_cpa.zip`
  - `kxj_k12_batch_002_100_cpa.zip`
- The second batch had 200 unique Gmail accounts, no email overlap with the 1334 bundle, and no missing access tokens in the verified run.
- A later `batch1.zip` example contained repeated emails with different account ids; those entries should be kept, not deduplicated by email.
- A later `50个.zip` example contained 50 CPA JSON files and should be kept as 50 entries when building its bundle.
- Replies in the second batch advised not importing everything at once. Use random/small slices.

Do not assume these exact files exist in a future workspace. Re-verify every time.

## Bundle Strategy

Create at least two classes of output when enough source material exists:

1. Recommended bundle:
   - high-confidence accounts only;
   - intended as the first server import;
   - small enough to test and recover from.
2. Full or optional bundles:
   - lower-confidence, newer, overlapping, or bulk packages;
   - clearly marked as optional;
   - imported only after recommended bundle works.

For volatile forum-shared K12 accounts, prefer a current-batch bundle and a small shuffled import:

```bash
export K12_BUNDLE="data/k12_sub2api_current_batch.json"
export K12_SHUFFLE=1
export K12_MAX_ACCOUNTS=10
bash run_on_server.sh
```

The exact `K12_MAX_ACCOUNTS` can be smaller for the first live test.

## Duplicate Handling Rules

For CPA single-account zip files:

- keep every JSON entry by default;
- use the builder's no-deduplication mode unless the user explicitly asks otherwise;
- report repeated emails and unique account-id counts;
- preserve same-email entries when account ids differ.

For grouped bundle zips:

- deduplicate cautiously across groups when building recommended/all bundles;
- do not deduplicate only by `chatgpt_account_id` or `account_id`, because some K12 packages share one workspace/account id across many distinct users;
- if unsure, preserve entries and explain the duplicate-risk rather than silently dropping them.

## Replacement Mode

When the user says "delete previous accounts", "only add this batch", "只加入这一批", or equivalent:

1. Do not delete original downloads unless explicitly asked.
2. Remove old generated bundle JSON/manifest files from the working kit's `data/` directory only after verifying they were produced by the current/previous kit workflow.
3. Generate a new current-batch bundle, preferably named `data/k12_sub2api_current_batch.json`.
4. Generate a matching manifest, preferably `data/k12_current_batch_manifest.json`.
5. Update `run_on_server.sh` default `K12_BUNDLE` to the current-batch bundle.
6. Update `README.md` and `SERVER_CODEX_PROMPT.md` so server-side Codex imports only the current batch by default.
7. Rebuild the deliverable zip and verify it does not contain old batch bundle names.
8. Report exactly what was deleted from the kit and what source archives were kept.

## Validation Commands

Use structured validation and do not print token values:

```bash
python scripts/import_sub2api_bundle.py \
  --base-url http://127.0.0.1:3000 \
  --bundle data/k12_sub2api_recommended_312.json \
  --max-accounts 3
```

For a second-batch or volatile package:

```bash
python scripts/import_sub2api_bundle.py \
  --base-url http://127.0.0.1:3000 \
  --bundle data/k12_sub2api_current_batch.json \
  --max-accounts 3 \
  --shuffle \
  --shuffle-seed 12345
```

Expected preview summary:

- `platforms` contains `openai`;
- `plan_types` contains `k12`;
- `missing_access_token` is `0`;
- sample identities show emails/names only, not tokens.

## Server Kit Pattern

Recommended directory shape:

```text
k12-sub2api-kit/
  README.md
  SERVER_CODEX_PROMPT.md
  run_on_server.sh
  data/
    k12_sub2api_recommended_*.json
    k12_sub2api_all_*.json
    k12_sub2api_current_batch.json
    *_manifest.json
  scripts/
    build_k12_bundle.py
    build_cpa_bundle.py
    import_sub2api_bundle.py
  docs/
    cpa_tutorial_summary.md
```

`README.md` should explain human usage.

`SERVER_CODEX_PROMPT.md` should tell the server-side Codex exactly what to do, in order, with secrets redacted in reports.

`run_on_server.sh` should:

- use `SUB2API_BASE_URL`, defaulting cautiously to localhost;
- use `K12_BUNDLE` with a safe default;
- support `K12_MAX_ACCOUNTS`;
- support `K12_SHUFFLE` and a fixed `K12_SHUFFLE_SEED` so preview and execute select the same accounts;
- run preview first, then execute.

## CPA Tutorial Relationship

The LINUX DO CPA tutorial teaches local CliProxyAPI use:

1. download CPA/CliProxyAPI;
2. copy `config.example.yaml` to `config.yaml`;
3. set `secret-key`;
4. run CPA;
5. log in at `http://localhost:8317/management.html#/login`;
6. upload `.json` account files;
7. create an API key;
8. point Cherry Studio/Codex/OpenAI-compatible clients to `http://localhost:8317`.

For a Sub2API deployment, CPA is background knowledge. If the goal is Sub2API import, convert the JSON files into Sub2API bundles and import directly. Do not deploy CPA unless the user asks for CPA specifically.

## Final Answer Requirements

For K12/Sub2API work, always report:

- what sources were read and whether any bookmarks/floors remain unread;
- downloaded files and their paths;
- generated/modified files;
- generated account counts;
- duplicate/overlap counts;
- missing token counts;
- whether tokens were refreshed: normally `no`;
- whether live import was executed: normally `no` unless explicitly authorized;
- commands used for validation;
- browser tabs opened/closed if browser was used;
- cleanup performed or intentionally not performed;
- running processes/services;
- commit hash if any commit was created.
