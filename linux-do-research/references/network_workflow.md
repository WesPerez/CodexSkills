# Unified Network-First Workflow For LINUX DO

Use this reference for the network-first pass of LINUX DO research. Treat it as the default path before any browser-plugin extraction.

## Proxy And Timeouts

For LINUX DO and `r.jina.ai` reader/search work, start with the local proxy immediately. Do not waste the first 20-30 seconds on direct requests that usually time out in this environment.

Use per-command proxy settings and short timeouts. Do not persist global proxy variables.

PowerShell examples:

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 "https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/2508374"
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 -A "Mozilla/5.0" "https://linux.do/t/topic/2508374.json"
```

If the local proxy is absent or fails with a proxy-connection error, make one short direct retry, usually `--max-time 15`, then move to another proxy-backed/search-index path. Record which path worked.

Do not persist global `HTTP_PROXY` or `HTTPS_PROXY`.

## Discovery Queries

Use search for discovery, not proof. Good patterns:

```text
site:linux.do K12 空间ID 被封 下车
site:linux.do K12 退出 工作空间
site:linux.do K12 下车 脚本
site:linux.do "K12灵车想跑路"
site:linux.do workspace deactivated K12
```

Search HTML may be noisy or CAPTCHA-gated. If output is only a search app shell, do not treat it as evidence.

## Reading Topics

Try topic reader URLs first:

```text
https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/<topic_id>
https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/<topic_id>/<floor>
```

Use position URLs to fill gaps:

- `/7` for early missing floors;
- `/14`, `/23`, `/30` for later ranges;
- the final visible floor number if the reader says "Skip to last reply".

Track:

```text
topic_url | title | visible_count/highest_floor | floors_read | floors_placeholder_only | gaps
```

Never claim all floors were read unless the expected/highest floor was known and every floor was extracted with body text or explicitly accounted for.

## Evidence Standard

Final claims should be grounded in original post text, not search summaries. Prefer:

- exact title and URL;
- quoted sentence or short passage;
- floor number or author/date when available;
- statement of whether the topic was complete or partial.

Separate:

- verified facts: directly quoted or observed;
- inferences: your synthesis from multiple facts;
- unresolved gaps: missing floors, blocked attachment, stale reader output.

## Attachments

Direct forum upload links often fail with Cloudflare:

```text
https://linux.do/uploads/short-url/<id>.txt
```

Try:

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 -A "Mozilla/5.0" "<forum-upload-url>"
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 "https://r.jina.ai/http://r.jina.ai/http://linux.do/uploads/short-url/<id>.txt"
```

If both fail, report the visible filename, visible size, source topic/floor, methods tried, and that browser escalation is required to resolve it. Do not say the attachment does not exist.

Download only when the attachment is necessary. Use explicit output paths and record bytes. If the file may contain tokens/accounts, inspect only structure, counts, keys, and presence booleans.

## When Network Is Enough

Network-only research is enough when:

- original topic body and relevant replies are readable;
- coverage is complete or gaps are irrelevant to the answer;
- key links/attachments are either read or not needed;
- the conclusion can be supported with direct quotes.

## When To Escalate

Escalate to browser fallback when:

- the user asked for every floor and reader output has placeholders;
- a key attachment/link is blocked;
- screenshots contain the only important evidence and cannot be interpreted from alt text;
- forum content appears private or reader output conflicts with other evidence;
- the answer would otherwise rest on summaries or guesses.

Before escalating, write down:

- queries used;
- topic URLs and floor-position URLs tried;
- proxy/direct path used;
- floors and links already covered;
- exact gaps that require browser help.

## Browser Escalation Guardrail

When the browser-plugin fallback is used, do not try to read LINUX DO by navigating the browser to `.json` topic URLs such as:

```text
https://linux.do/t/topic/<topic_id>.json
```

Those browser navigations are commonly blocked by Cloudflare. Use the normal topic URL and topic-position URLs instead:

```text
https://linux.do/t/topic/<topic_id>
https://linux.do/t/topic/<topic_id>/<floor>
```

Then extract DOM-visible posts and open targeted position pages to fill missing floors. Shell/network JSON may still be tried during the network pass when reachable without browser credentials; the prohibition is specifically for browser/plugin fallback navigation.
