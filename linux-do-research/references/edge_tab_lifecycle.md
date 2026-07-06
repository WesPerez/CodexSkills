# Edge Tab Lifecycle For LINUX DO Research

Use this reference before controlling the browser for LINUX DO. Browser control is the fallback stage of the same `linux-do-research` skill, not the default path for ordinary searches.

## Browser Selection

- Default to Microsoft Edge.
- Do not use Chrome unless the user explicitly requests Chrome.
- If the available automation module path contains `chrome`, still verify the actual controlled tabs are Edge tabs. Plugin package names can be misleading.
- Do not use browser fallback until the network-first pass has produced a concrete evidence gap, unless the user explicitly asked for an existing browser tab, bookmarks, or current-tab work.

## Initial Audit

Before reading:

1. List open browser tabs via the official browser extension.
2. Record each relevant tab's id, title, and URL.
3. Identify the user-owned target tab:
   - user gave exact URL;
   - user gave title substring, for example "第二批";
   - page title and URL match the request.
4. Prefer claiming that tab over opening a new tab.

Never close a user-owned tab solely because you claimed it for automation.

## Temporary Tab Registry

When a new tab is necessary, internally record:

- tab id;
- purpose;
- requested URL;
- final URL;
- final title;
- whether closed;
- any error;
- why the tab was needed.

Examples of valid temporary tab purposes:

- read cloaked floors 6-8 at `/7`;
- verify floors 9-15 at `/10`;
- read a linked tutorial topic;
- resolve a forum upload short URL to a CDN URL.

Do not create many tabs in parallel unless the user explicitly asks and tab cleanup is manageable. For most topic reads, one temporary tab at a time is safer.

## Closing Rules

Only close a tab when all are true:

1. The tab id is in the current task's temporary tab registry.
2. The URL/title still match the recorded purpose.
3. The tab is no longer needed.
4. Closing it will not remove the user's original target tab.

If close returns but the tab still appears in a stale list, perform one independent open-tab audit. If the tab is truly gone, do nothing. If it remains and still matches the recorded temporary tab, close it once more.

Never close:

- tabs that existed before the task and were not explicitly assigned for closure;
- ambiguous tabs;
- unrelated user tabs;
- browser/system/extension tabs;
- another agent's or another session's tabs.

## Official Extension Pattern

Typical Node REPL setup:

```js
var pluginRoot = "C:/Users/Wes/.codex/plugins/cache/openai-bundled/chrome/26.602.40724";
var browserModule = await import(pluginRoot + "/scripts/browser-client.mjs");
await browserModule.setupBrowserRuntime({ globals: globalThis });
globalThis.browser = await agent.browsers.get("extension");
var tabs = await browser.user.openTabs();
```

Do not navigate browser/plugin tabs to LINUX DO `.json` topic URLs such as `https://linux.do/t/topic/<id>.json`; use normal topic pages and topic-position pages, then extract DOM-visible posts.

Claim an existing tab:

```js
var tab = await browser.user.claimTab("<tab-id>");
```

Create a temporary tab:

```js
var temp = await browser.tabs.new();
await temp.goto("https://linux.do/t/topic/123/10");
```

Close a known temporary tab:

```js
await temp.close();
```

## Read-Only Page Scope Limits

In the official plugin, `tab.playwright.evaluate(...)` is read-only and may not expose normal browser APIs such as `fetch`, `XMLHttpRequest`, `NodeFilter`, or full `performance`.

Prefer DOM extraction inside `evaluate`. If network JSON access fails in page scope, do not assume the website is down; switch to DOM/topic-position extraction.

## User Updates

For long reads, tell the user:

- which existing tab you claimed;
- why a temporary tab is needed;
- when the temporary tab is closed;
- whether coverage is complete or still has gaps.

Avoid saying "done" while tabs remain un-audited.

## Final Tab Report

Final response must include:

- user-owned tabs retained;
- temporary tabs opened and closed;
- tabs left open and why;
- any failed close attempts and follow-up audit result.
