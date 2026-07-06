# Sub2API Import Contract

Use this reference when importing K12 bundles into Sub2API or writing server-side instructions.

## Known API Contract

Verified frontend/API facts:

- Login endpoint: `POST /auth/login`
- Account export/import endpoint: `GET /admin/accounts/data?include_proxies=false`
- Account import endpoint: `POST /admin/accounts/data`
- Auth header: `Authorization: Bearer <auth_token>`
- Import payload shape:

```json
{
  "data": {
    "exported_at": "...",
    "proxies": [],
    "accounts": []
  },
  "skip_default_group_bind": false
}
```

Responses may be wrapped as:

```json
{
  "code": 0,
  "data": {}
}
```

Treat nonzero `code` as an API error.

## Authentication Options

Use one of:

1. `SUB2API_AUTH_TOKEN`: admin bearer token.
2. `SUB2API_LOGIN` and `SUB2API_PASSWORD`: login through `/auth/login`.
3. `SUB2API_COOKIE`: only if the user/server explicitly provides it. Do not extract browser cookies.

Login payloads to try:

- `{ "email": login, "password": password }` when login contains `@`;
- `{ "username": login, "password": password }`;
- `{ "account": login, "password": password }`.

Do not print secrets.

## Preview First

Preview does not post the import payload. It should:

- load the bundle;
- summarize account count, platforms, plan types, missing access token count;
- print sample identities only, not token values;
- optionally fetch existing accounts when auth is available and `--skip-existing` is requested;
- optionally apply shuffle and max account limits.

Example:

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_recommended_312.json \
  --skip-existing
```

If auth is missing and `--skip-existing` is requested, fail clearly rather than silently importing duplicates.

## Execute Import

Execute only after preview succeeds and the user has authorized live import:

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_recommended_312.json \
  --skip-existing \
  --execute
```

For volatile packages:

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_current_batch.json \
  --skip-existing \
  --shuffle \
  --shuffle-seed "$K12_SHUFFLE_SEED" \
  --max-accounts 10 \
  --execute
```

Use the same shuffle seed for preview and execute. A wrapper script should generate one seed and reuse it.

## Existing Account Skip

Fetch existing account data with:

```http
GET /admin/accounts/data?include_proxies=false
Authorization: Bearer <token>
```

Collect identity keys using:

- email;
- name;
- chatgpt/account id only as fallback.

Filter bundle accounts before import and report:

- existing accounts seen;
- existing identity keys;
- skipped existing;
- remaining accounts.

## Server Base URL Discovery

Prefer explicit `SUB2API_BASE_URL`.

If absent, try likely local URLs cautiously:

- `http://127.0.0.1:3000`
- `http://127.0.0.1:8080`

If the server has deployment config, inspect it read-only to find the reverse proxy or service port.

Do not mutate service config merely to find the API.

## Verification After Import

Verify via API or admin UI:

- accounts exist;
- platform is OpenAI;
- auth type is OAuth;
- plan type is K12;
- imported accounts are not all paused;
- a small sample can be tested;
- no batch refresh was triggered.

Report errors and partial imports precisely.

## Failure Handling

If the API returns errors:

- preserve the bundle files;
- do not retry with a larger batch;
- retry with `--max-accounts 1` only if safe and authorized;
- check whether auth expired;
- check whether payload shape changed;
- check whether server-side validation rejects missing optional fields;
- never "fix" by refreshing all tokens.

If import partially succeeds:

- fetch existing accounts;
- use `--skip-existing`;
- continue with a smaller batch only after explaining the state.

## Security Boundaries

Allowed without extra authorization:

- read local bundle files;
- run preview mode;
- inspect server config read-only;
- validate JSON structure;
- produce commands/prompts.

Needs explicit authorization:

- live import `--execute`;
- editing Sub2API config;
- restarting services;
- deleting/pausing accounts;
- refreshing tokens;
- exporting live account data beyond identity counts.

Forbidden unless the user provides a narrow, explicit instruction and it is safe:

- extracting browser cookies;
- reading browser localStorage/sessionStorage for auth;
- publishing account bundles;
- printing tokens;
- production database writes.
