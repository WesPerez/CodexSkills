---
name: codex-plugin-troubleshooter
description: Diagnose and repair Codex Desktop plugin/tool exposure problems, especially Chrome, Browser Use, Computer Use, node_repl, mcp__node_repl__js, codex_apps, app connectors, Edge/Chrome Native Messaging Host issues, tool_search misses, and Codex update/runtime path regressions. Use when Codex browser or desktop-control plugins are installed but unavailable, when official plugin skills cannot call their required Node REPL tool, when config.toml or CC Switch may be overwriting plugin settings, or when OpenAI docs/community evidence must be gathered through proxies or alternate official/community sources.
---

# Codex Plugin Troubleshooter

## Core Rule

Prove the failing layer before editing config. The common trap is treating all plugin failures as one thing. Split the stack:

1. Skill exists and is enabled.
2. Required MCP server is configured.
3. MCP server starts and lists tools.
4. Current model-visible tool surface exposes the tool, directly or through tool discovery.
5. Plugin runtime connects to Chrome/Edge/Computer Use.
6. Browser/native host side can see tabs or apps.
7. Config survives Codex restart and CC Switch/provider switches.

Only fix the first broken layer.

## Fast Workflow

1. Read the relevant bundled skill first:
   - Chrome: `chrome:control-chrome`
   - in-app browser: `browser:control-in-app-browser`
   - Computer Use: `computer-use:computer-use`
2. Check the current callable tools. If `mcp__node_repl__js` is present, use it. If only `js_reset` or `js_add_node_module_dir` is present, use tool discovery for `node_repl js` before declaring failure.
3. If `mcp__node_repl__js` is absent, check whether Codex internally sees `node_repl` but does not expose it to the model. This points at tool-surface routing, not Chrome.
4. Inspect `~/.codex/config.toml`, CC Switch provider templates, and `chrome-native-hosts-v2.json` for these keys:
   - `[features] apps = false`
   - `[mcp_servers.node_repl]`
   - `CODEX_CLI_PATH`
   - `NODE_REPL_NODE_PATH`
   - `NODE_REPL_NODE_MODULE_DIRS`
   - `BROWSER_USE_AVAILABLE_BACKENDS`
   - `[plugins."chrome@openai-bundled"] enabled = true`
5. Verify the official runtime through `mcp__node_repl__js` before using Windows UI fallback.
6. Run the smallest persistent repair, then start a new turn/thread or restart Codex Desktop. Current request tool lists do not hot reload.

For the full case history and exact commands, read `references/casebook.md`.

## Historical Context

If the user asks for a root-cause audit or says this worked before, read local history when available before concluding:

- pasted attachments under `~/.codex/attachments`
- `~/.codex/.codex-global-state.json` prompt history snippets
- prior local notes or summaries the user pasted into the current thread
- Codex/CC Switch config and dry-run output

Search narrowly for exact symptoms such as `mcp__node_repl__js`, `node_repl`, `codex_apps`, `features.apps`, `Chrome Plugin`, `Computer Use`, `CODEX_CLI_PATH`, `openaiDeveloperDocs`, and `NativeMessagingHosts`. Do not read unrelated personal data just because it is nearby.

## Known Root Causes

- `features.apps = true` can flood the tool surface with `codex_apps` connector tools and hide `mcp__node_repl__js` in affected Desktop builds. Official docs say `apps` defaults to `false` and is only for ChatGPT Apps/connectors support.
- `openaiDeveloperDocs` MCP once caused similar model-visible tool issues on custom providers. Disable it unless the task specifically needs Docs MCP and it is verified healthy.
- Codex updates can change bundled runtime paths. Repair stale `node_repl.exe`, `node.exe`, `node_modules`, and Chrome `latest` junctions from the current native-host registry.
- Do not force-rewrite a valid `CODEX_CLI_PATH` just because another registry entry differs. If the path exists and works, preserve it.
- Edge can work through the Chrome extension chain when the Codex extension is installed and Edge has the Native Messaging Host registry entry. Do not conclude "Edge unsupported" before checking that registry.
- A working MCP server is not enough. The model must actually see or discover `mcp__node_repl__js`.

## Official Docs And Community Lookup

Use official OpenAI docs first. If direct requests fail with `403`, `Vercel-Mitigated: deny`, timeout, or regional blocking:

1. Check local proxy ports without changing persistent config: common ports are `10808`, `7890`, `7897`, and `1080`.
2. Use a temporary command-level proxy, for example:

```powershell
curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://developers.openai.com/codex/codex-manual.md
```

3. If Windows Schannel blocks GitHub API through the proxy with revocation errors, use `curl.exe -k` for that one read-only lookup only.
4. Search GitHub issues and forums for the exact symptom strings:
   - `mcp__node_repl__js unavailable Codex Desktop`
   - `unsupported call: mcp__node_repl__js`
   - `codex_apps node_repl tool list`
   - `Codex Desktop node_repl Chrome Computer Use`
5. Also search official/community support surfaces when available: OpenAI docs, OpenAI Help/Community pages, GitHub Issues, GitHub Discussions, and release/changelog pages.

Treat community posts as leads, not authority. Confirm with local behavior and official docs when reachable.

## Repair Discipline

- Prefer a no-op dry run before writes.
- Back up before editing `config.toml` or CC Switch DB/provider templates.
- Do not clear plugin caches, reinstall extensions, or reset Codex unless the broken layer proves that is necessary.
- Do not inspect cookies, browser storage, passwords, or session stores.
- After repair, verify with the official plugin path, for example `agent.browsers.get("extension")` and `browser.user.openTabs()`.
