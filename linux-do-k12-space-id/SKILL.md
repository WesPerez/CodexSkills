---
name: linux-do-k12-space-id
description: Fast LINUX DO K12 ChatGPT/OpenAI workspace/space ID collection workflow. Use when Codex needs to search or summarize LINUX DO posts for K12 空间ID, 工作区ID, workspace IDs, Gmail/Outlook K12 IDs, source-marked recent K12 space IDs, or publication-order K12 ID lists without wasting time on blocked direct requests.
---

# LINUX DO K12 Space ID

## Core Rule

Use this skill together with `linux-do-research`, but keep the path narrow: proxy-first network reads, candidate topic discovery, reader verification, UUID extraction, source marking, and final audit. Do not spend time on direct `linux.do`/`r.jina.ai` waits before trying the local proxy.

Default every network request to:

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 35 "<url>"
```

If the proxy is absent or returns a proxy-connection error, make one short direct retry with `--max-time 15`, then continue with other proxy-backed/search-index paths. Do not persist `HTTP_PROXY` or `HTTPS_PROXY`.

## Fast Workflow

1. Interpret "最近的 N 个帖子" as topic publication order, not reply/activity order.
2. Start from known high-yield discovery routes:
   - reader for the K12 aggregation topic: `https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/2514402`;
   - search queries through proxy-backed DDG/other search HTML:
     - `site:linux.do/t/topic K12 空间ID`
     - `site:linux.do/t/topic K12 工作区ID`
     - `site:linux.do/t/topic K12 gmail 空间`
     - `site:linux.do/t/topic "空间Id是"`
     - exact titles discovered from related-topic tables.
3. Extract candidate topic IDs from all `https?://linux.do/t/topic/<id>` URLs. Keep title text when available.
4. Sort candidates by verified `Published Time` after fetching. Before verified timestamps are available, use topic ID descending only as a temporary approximation.
5. Fetch each candidate with the Jina reader URL:
   `https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/<id>`
6. For each topic, record:
   - topic ID, title, URL, `Published Time`;
   - whether the reader returned original post text, private/404, rate limit, or empty/TLS failure;
   - UUIDs extracted from visible text, attachment filenames, and decoded obfuscation;
   - status warnings such as `已失效`, `结束`, `deactivated_workspace`, `Payment Required`, `429`, or replies saying unusable.
7. Deduplicate by UUID, but keep every source where it appeared.
8. Output a source map plus a plain text ID list:
   `uuid | source(s) | status/note`.

## What To Avoid

- Do not begin with direct `linux.do/search.json` or direct forum search pages; they commonly return Cloudflare, 429, or long waits.
- Do not use `/latest` as publication order. It is reply/activity order. Use it only to discover recent topic URLs, then verify each topic's `Published Time`.
- Do not treat search snippets as final evidence. Mark them as `search-snippet only` unless a reader page confirms the content.
- Do not download account bundles or attachments just to find space IDs. Attachment filenames such as `sub2api-workspace-<uuid>.zip` are enough to record an inferred workspace ID; mark it as filename-derived unless body text confirms it.
- Do not decode or print access tokens, OAuth credentials, or full account JSON. Only extract non-secret IDs and source metadata.
- Do not use browser fallback unless the user asks for browser/logged-in reading or the final answer would otherwise be materially wrong. If browser fallback is used, follow `linux-do-research` tab lifecycle rules.

## Extraction Rules

Recognize UUID-like space IDs with:

```text
\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b
```

Treat as stronger evidence when a UUID appears near:

- `空间`, `空间ID`, `空间Id`, `工作区`, `工作区ID`, `workspace`;
- filenames like `sub2api-workspace-<uuid>.zip`;
- replies explicitly saying `空间Id是 <uuid>`.

Treat as weaker/inferred evidence when a UUID appears only in:

- a generic `sub2api_<uuid>_*.zip` filename;
- `request id`, `chatgpt_account_id`, or account JSON fields;
- error logs. In these cases, include it only if the surrounding text clearly ties it to a workspace/space ID, or mark the reason for uncertainty.

Handle obfuscation seen in LINUX DO K12 posts:

- remove inserted marker words such as `编码或解码` inside base64 strings;
- normalize whitespace;
- decode base64 chunks when the decoded text contains UUIDs;
- record that the IDs were decoded from visible post text.

## Helper Script

Use `scripts/collect_k12_space_ids.py` for the standard pass:

```powershell
python "C:\Users\Wes\.codex\skills\linux-do-k12-space-id\scripts\collect_k12_space_ids.py" --limit 30
```

Useful options:

```powershell
python "...collect_k12_space_ids.py" --limit 30 --extra-id 2531263 --extra-id 2531087
python "...collect_k12_space_ids.py" --candidate-id 2533655 --candidate-id 2531263 --candidate-id 2531087
python "...collect_k12_space_ids.py" --json
```

The script uses the proxy first, never writes files, does not download attachments, and prints source-marked results. After running it, manually inspect any high-value private, failed, or search-snippet-only topics if the user asked for maximum coverage.

## Final Report

Include:

- the exact ordering basis: verified `Published Time` first, topic ID fallback if needed;
- source map with topic ID, title, URL, and publish time;
- deduplicated ID text list with source labels;
- private/404 or unread recent candidates that could not be verified;
- whether proxy was used;
- whether any browser tabs were opened/closed;
- downloaded files: normally `none`;
- generated files: normally `none`;
- config/env changes: normally `none`.
