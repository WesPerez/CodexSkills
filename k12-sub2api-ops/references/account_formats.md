# K12 Account Formats

Use this reference when inspecting, converting, or validating K12 account packages. Never print raw token values.

## Sub2API Bundle JSON

Shape:

```json
{
  "exported_at": "2026-07-05T00:00:00+00:00",
  "proxies": [],
  "accounts": [
    {
      "platform": "openai",
      "type": "oauth",
      "name": "account-name",
      "credentials": {
        "access_token": "...",
        "email": "user@example.com",
        "id_token": "...",
        "refresh_token": "",
        "plan_type": "k12",
        "chatgpt_account_id": "...",
        "account_id": "...",
        "expires_at": 1783946504
      }
    }
  ]
}
```

Minimum required for this workflow:

- top-level `accounts` is a list;
- every account uses `platform=openai`;
- every account uses `type=oauth`;
- every account has `credentials.access_token`;
- every account has `credentials.plan_type=k12`;
- every account has an identity such as `credentials.email` or `name`.

Useful optional fields:

- `auto_pause_on_expired: true`
- `concurrency: 10`
- `priority: 1`
- `rate_multiplier: 1`
- `extra.source`
- `extra.email`
- `credentials.id_token`
- `credentials.refresh_token` if present in the source
- `credentials.client_id`
- `credentials.expires_at`

## CPA Single-Account JSON

Shape commonly seen in forum CPA zip packages:

```json
{
  "access_token": "...",
  "account_id": "...",
  "email": "user@gmail.com",
  "expired": "2026-07-15T04:07:22+00:00",
  "id_token": "...",
  "last_refresh": "2026-07-05T04:07:22+00:00",
  "refresh_token": "",
  "type": "codex"
}
```

Convert one file into one Sub2API account:

- `platform`: `openai`
- `type`: `oauth`
- `name`: email local part, sanitized
- `credentials.access_token`: source `access_token`
- `credentials.email`: source `email`
- `credentials.id_token`: source `id_token`
- `credentials.refresh_token`: source `refresh_token` if present, otherwise empty string
- `credentials.chatgpt_account_id`: source `account_id`
- `credentials.account_id`: source `account_id`
- `credentials.expires_at`: unix timestamp parsed from `expired`
- `credentials.plan_type`: `k12`
- `extra.source`: source zip basename
- `extra.source_entry`: original zip entry path
- `extra.source_type`: source `type`
- `extra.last_refresh_at`: parsed timestamp from `last_refresh`

Do not assume `refresh_token` exists. Many shared CPA files have access/id token only.

For CPA single-account zip files, default to keeping every JSON entry. Do not remove entries merely because the email repeats. A repeated email can legitimately have different `account_id` / `chatgpt_account_id` values and should be imported as separate accounts unless the user asks to deduplicate or the entries are proven identical by account id and token.

## Grouped K12 Bundle Zip

Some zip files contain several Sub2API-style bundle JSON files, for example:

- `k12_5h_high_36.json`
- `k12_5h_mid_73.json`
- `k12_5h_full_203.json`
- `k12_5h_low_1022.json`

Handle these by reading the named JSON entries and combining their `accounts` lists with cautious deduplication, because these grouped bundles often intentionally repeat the same workspace id across many emails.

Typical strategy:

- recommended bundle: high + mid + full groups;
- all bundle: high + mid + full + low groups;
- manifest: record per-group input count, added count, and duplicates skipped.

## Identity And Deduplication

Use this identity function only when deduplication is explicitly part of the task:

1. exact `credentials.account_id` / `chatgpt_account_id` plus `credentials.email`, when both are present;
2. exact access token prefix, when comparing suspected exact duplicate files;
3. `credentials.email` or top-level `email`, only for grouped bundles where repeated email should not produce multiple accounts;
4. top-level `name`, only when no better identity exists.

Reason: there are two opposite failure modes. Some K12 dumps share one ChatGPT workspace/account id across many distinct users, so account id alone can collapse valid accounts. Other CPA zips can contain the same email with different account ids, so email alone can collapse valid accounts. Deduplication must be format-aware and evidence-based.

## Secret-Safe Inspection

Use counts and keys instead of token output:

- zip entry names;
- top-level JSON keys;
- credential keys;
- `HasAccessToken=true/false`;
- `HasRefreshToken=true/false`;
- email/name sample only if acceptable;
- token string lengths only if needed.

Redact keys matching:

- `access_token`
- `refresh_token`
- `id_token`
- `session_token`
- `authorization`
- `cookie`
- `bearer`

## Validation Checklist

For every generated bundle:

- account count matches manifest;
- account count matches source-entry count unless deduplication was explicitly requested;
- repeated emails are reported with account-id counts rather than removed automatically;
- `missing_access_token = 0`;
- all `platform` values are `openai`;
- all `type` values are `oauth`;
- all plan types are `k12`;
- no bundle accidentally contains cookies or browser session storage;
- no raw tokens were printed into logs or docs.
