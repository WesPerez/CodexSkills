---
name: linux-do-research
description: Unified network-first LINUX DO research workflow for forum searches, K12 posts, topic evidence, replies/floors, links, attachments, bookmarks, and browser-backed verification. Use pure network search/readers first; use Microsoft Edge/browser-plugin fallback only when network evidence is incomplete, untrusted, blocked, or the user explicitly asks for Edge/browser/current-tab/bookmark/logged-in-visible details.
---

# LINUX DO Research

## Core Rule

Use this skill as the single entry point for LINUX DO research. Always start with pure network methods unless the user gives a specific existing browser tab/bookmark page/current-tab target that cannot be represented as a URL or search query.

In this environment, start LINUX DO and `r.jina.ai` network requests with the local proxy `http://127.0.0.1:10808` and command-local timeouts. Do not spend the initial pass waiting on direct requests that usually time out.

Prefer network search and reader pages because they are quieter, safer, and easier to audit. Use Microsoft Edge/browser-plugin fallback only when network methods cannot produce enough original, verifiable evidence, or when the user explicitly requests browser/current-tab/bookmark/logged-in-visible forum work.

Do not use Edge, Chrome, browser plugins, cookies, localStorage, sessionStorage, saved passwords, or forum-auth headers during the network pass.

When using the browser fallback, use Microsoft Edge by default. Prefer the user's existing Edge tab. Do not use Chrome unless the user explicitly asks for Chrome. Track every temporary tab you create, close only tabs proven created by this task, and report tab handling in the final answer.

Do not navigate browser/plugin tabs to `https://linux.do/t/topic/<id>.json`. Those pages are commonly blocked by Cloudflare in the browser path and waste time. Use normal topic URLs and targeted topic-position URLs (`/<floor>`) and extract DOM-visible content instead. Shell/network JSON may still be tried during the network pass when it is reachable without browser credentials.

## Required Reading

Read `references/network_workflow.md` before doing LINUX DO research, especially before claiming floor coverage, downloading attachments, or deciding whether browser fallback is necessary.

Read `references/edge_tab_lifecycle.md` before using browser automation.

Read `references/discourse_extraction.md` before claiming that all floors/replies were read.

Read `references/attachments_and_links.md` before downloading attachments or following links.

Use `references/research_audit_template.md` to maintain coverage notes for bookmarks, floors, links, attachments, and tab cleanup.

## Workflow

1. Clarify the research target from the user request:
   - exact topic URL or topic ID;
   - search terms and synonyms;
   - bookmarks page, current Edge tab title, all floors, selected links, attachments, or tutorials;
   - whether they need every floor/attachment/link or only a focused answer.
2. Discover candidate URLs without browser plugins:
   - use search engines through proxy-backed `curl` when available;
   - use `site:linux.do` queries and exact quoted titles;
   - treat search snippets as discovery only, not final evidence.
3. Read original topic content through network methods:
   - try `https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/<id>`;
   - try targeted topic-position URLs such as `/7`, `/14`, `/30` for missing ranges;
   - try direct Discourse JSON only from shell/network when it is reachable without browser credentials.
4. Track network coverage before concluding:
   - title, URL, visible post count or highest floor;
   - floors actually read;
   - floors only seen as placeholders;
   - links and attachments discovered;
   - remaining gaps and why they matter.
5. Escalate to browser fallback only for the specific gaps when:
   - the user explicitly asks to use Edge/browser, an existing tab, bookmarks, logged-in state, or plugin-based reading;
   - network output has only summaries/snippets and not original post text;
   - important floors are missing, cloaked, or only visible as placeholders;
   - a key attachment, image, linked tutorial, or CDN redirect cannot be resolved without the browser;
   - the question requires strong evidence and the network path leaves a material gap;
   - direct requests are blocked by Cloudflare and Jina/search caches are stale, incomplete, or contradictory.
6. If browser fallback is needed, audit open Edge tabs:
   - identify the user-owned target tab by title/URL;
   - do not open a duplicate if the existing tab satisfies the task.
7. Read browser pages efficiently:
   - use DOM extraction from the current topic;
   - if floors are cloaked/lazy-loaded, open one targeted temporary topic-position tab such as `/7` or `/10`, extract the missing range, then close it.
8. Track final coverage:
   - record title, URL, expected post count/highest floor if visible;
   - record floor numbers successfully read;
   - record gaps and how they were closed;
   - do not claim full coverage until gaps are resolved.
9. Follow links only when useful:
   - prioritize linked tutorials, source posts, attachment links, and links mentioned as instructions;
   - avoid wandering into unrelated discussions.
10. Download attachments only when needed:
   - try network-safe reads first;
   - resolve forum short URLs through Edge if Cloudflare blocks direct requests;
   - download from the resolved CDN URL if it does not require cookies;
   - verify file path, size, and structure.
11. Summarize findings with evidence:
   - network methods used and whether browser fallback was necessary;
   - topic and floor coverage;
   - attachments and downloaded files;
   - key warnings/instructions from replies;
   - unresolved gaps.

## Browser Safety

Never extract browser cookies, localStorage, sessionStorage, saved passwords, profile files, or auth headers. Do not post, like, bookmark, reply, upload, or otherwise mutate forum state unless explicitly requested.

## Final Audit

Before final response:

- report network methods used and whether a local proxy was used;
- report URLs read and exact floor coverage;
- report links followed and attachments attempted/downloaded;
- report files created or downloaded, with absolute paths and sizes;
- report cleanup actions or retained artifacts;
- report whether browser escalation was needed or deliberately not used;
- run an Edge tab audit;
- close only known task-created temporary tabs that are no longer needed;
- keep user-owned or ambiguous tabs open;
- report opened tabs, closed tabs, retained tabs, and tabs not closed due to unclear ownership;
- report downloads and generated files;
- report whether all requested floors/bookmarks were actually read.
