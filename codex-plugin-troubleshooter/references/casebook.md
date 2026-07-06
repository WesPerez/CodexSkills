# Codex Plugin Troubleshooter Casebook

## Why This Exists

This reference captures the local debugging path for repeated Codex Desktop plugin failures where Chrome, Browser Use, Computer Use, or `node_repl` looked installed but the model could not call the official tools.

Use it when the live symptom is confusing, when several fixes were tried before, or when Codex updates/CC Switch may have rewritten working settings.

## Local Timeline

1. Chrome/Computer Use plugins were enabled but the model did not receive `mcp__node_repl__js`.
2. First confirmed that installed plugin icons and skill injection are not enough. The model-visible tool list is a separate layer.
3. Found one earlier failure where `openaiDeveloperDocs` MCP polluted or crowded the tool surface on custom provider runs. Disabling it fixed one round.
4. After a Codex update, runtime paths changed. Old configs pointed at stale `node_repl.exe`, `node.exe`, `node_modules`, or Chrome `latest` junctions. `repair-runtime` was added to CC Switch tooling.
5. Edge initially looked unsupported only because Edge Native Messaging Host registration was missing. Adding `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension` restored that side.
6. A later failure was different: Codex logs showed `node_repl` was discovered, but the current request still exposed only a small tool set and no direct `mcp__node_repl__js`.
7. Evidence showed `codex_apps` was present with a very large tool count while `node_repl` had only 3 tools. Setting `[features] apps = false` restored direct `mcp__node_repl__js` exposure after restart/new turn.
8. Official Chrome plugin runtime was then verified through `mcp__node_repl__js` by importing the bundled `browser-client.mjs`, calling `agent.browsers.get("extension")`, and listing open tabs.
9. A final script correction preserved an existing, working `CODEX_CLI_PATH` instead of forcing it back to an older `.plugin-appserver` alpha binary. Runtime repair now cleans stale paths and temporary `SKY_CUA_*` pipe env without fighting a valid Codex CLI path.

## Official Findings

The OpenAI Codex manual says:

- `[features]` controls optional and experimental capabilities.
- `apps` default is `false`.
- `apps` is Experimental and means "Enable ChatGPT Apps/connectors support".
- App/connectors have their own `[apps]` controls and are separate from MCP and bundled browser plugins.

Therefore `features.apps = false` should not disable Chrome, Browser Use, Computer Use, or `node_repl`. It disables ChatGPT app/connectors support such as `codex_apps` connector tooling.

## Community Evidence

GitHub issue `openai/codex#28481` reported:

- `mcp__node_repl__js` unavailable in Codex Desktop 26.609 on Windows.
- `node_repl` was configured and the runtime existed, but the model tool list did not expose the tool.
- Browser and Computer Use workflows were unusable because they depend on Node REPL.
- Later comments showed similar failures on newer Windows Desktop builds and a partial fix where registration improved but routing still had defects.

Use this as proof that the symptom can be a Codex Desktop tool-exposure/routing problem, not only a local machine misconfiguration.

## Evidence Checklist

Collect these before fixing:

```powershell
Select-String -Path "$env:USERPROFILE\.codex\config.toml" -Pattern '^\[features\]|apps\s*=|openaiDeveloperDocs|node_repl|CODEX_CLI_PATH|BROWSER_USE'
Get-Content "$env:USERPROFILE\.codex\chrome-native-hosts-v2.json"
codex mcp get node_repl
codex mcp list
codex plugin list
```

When a current tool list is available, check whether `mcp__node_repl__js` is directly callable. If not, use tool discovery for `node_repl js`. If discovery also fails while `codex mcp get node_repl` succeeds, suspect tool exposure.

## Official Chrome Runtime Probe

Use only when `mcp__node_repl__js` is available:

```js
const { setupBrowserRuntime } = await import("file:///C:/Users/Wes/.codex/plugins/cache/openai-bundled/chrome/26.602.40724/scripts/browser-client.mjs");
await setupBrowserRuntime({ globals: globalThis });
globalThis.browser = await agent.browsers.get("extension");
const tabs = await browser.user.openTabs();
nodeRepl.write(JSON.stringify({ count: tabs.length, sample: tabs.slice(0, 5).map(t => ({ title: t.title, url: t.url })) }, null, 2));
```

Versioned plugin paths can change. Resolve the current plugin version before running this on another machine.

## Local Proxy Lookup Pattern

When official docs or GitHub are blocked:

```powershell
foreach($p in 10808,7890,7897,1080) {
  "$p " + (Test-NetConnection 127.0.0.1 -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue)
}

curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://developers.openai.com/codex/codex-manual.md
curl.exe -k -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://api.github.com/repos/openai/codex/issues/28481
```

Use the proxy only for the lookup unless the user explicitly asks to persist proxy config.

## Decision Tree

- `mcp__node_repl__js` visible and Chrome probe works: plugin chain is healthy.
- `mcp__node_repl__js` visible but Chrome probe times out: inspect Chrome/Edge extension, Native Messaging Host, and browser process state.
- `node_repl` configured but `mcp__node_repl__js` not visible: inspect `features.apps`, `openaiDeveloperDocs`, current Desktop version, and tool-surface logs.
- `node_repl` missing or paths stale: repair runtime paths from `chrome-native-hosts-v2.json`.
- Edge tabs not visible but Chrome works: check Edge extension install and Edge Native Messaging Host registry.
- Fix works only until CC Switch/provider switch: sync the known-good config into CC Switch provider templates and `proxy_live_backup`.

## Final Known-Good Local Shape

```toml
[features]
apps = false

[plugins."chrome@openai-bundled"]
enabled = true

[mcp_servers.openaiDeveloperDocs]
enabled = false

[mcp_servers.node_repl]
type = "stdio"
startup_timeout_sec = 120
```

Do not blindly copy paths between machines. Runtime paths are installation-specific.
