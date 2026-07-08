---
name: browser-bookmarks
description: Safely organize, deduplicate, migrate, back up, restore, or inspect Chromium browser bookmarks and favorites, especially Microsoft Edge and Google Chrome profile `Bookmarks` files. Use when a user asks Codex to clean up Edge/Chrome favorites, preserve bookmark bar habits, move items across folders, copy Edge bookmarks to Chrome, recover from sync overwrites or duplicate bookmark trees, validate backups, handle bookmark checksum issues, or reason about favicon/bookmark sync side effects.
---

# Browser Bookmarks

## Operating Contract

Inputs: target browser, profile path, user intent, preservation rules, and permission state for closing browser windows or background processes.

Outputs: backup paths, before/after inventory, mutation method, verification evidence, cleanup report, and restore instructions.

Status labels: `audit-only`, `backup-created`, `api-mutation-applied`, `raw-file-fallback-applied`, `restore-ready`, `partial-sync-verified`, `blocked-needs-browser-close`, `blocked-needs-user-authorization`, `blocked-cloud-state-unknown`.

Handoff: use `chrome:control-chrome` only when the user explicitly wants Chrome browser control or existing Chrome state; use `browser:control-in-app-browser` for in-app browser work; use `computer-use:computer-use` only when native UI interaction is required. Prefer local file inspection and Chromium bookmark APIs for bookmark work.

## Start Checklist

1. Identify the browser and profile exactly. In this Windows environment, default to Microsoft Edge unless the user explicitly says Chrome. Edge usually lives under `%LOCALAPPDATA%\Microsoft\Edge\User Data\<Profile>`, Chrome under `%LOCALAPPDATA%\Google\Chrome\User Data\<Profile>`. Read `Local State` when the active profile is unclear.
2. Record whether the user authorized closing windows/background processes. If not authorized, ask before closing or killing anything. If authorized, still close only the target browser processes and explain why background processes exist.
3. Create a timestamped backup of the live `Bookmarks` file before any mutation. Also back up `Favicons` before any icon work.
4. Run `scripts/chromium_bookmarks_audit.mjs` on the current file. When preserving bookmark bar habits, also run it against the backup after changes with `--baseline`.
5. Define preservation rules before changing anything: direct URLs on the bookmark bar, pinned high-frequency folders, duplicate URLs that are intentional shortcuts, mobile/synced roots, and any folders the user said not to merge.

## Decision Tree

- For read-only diagnosis, backup planning, or restore planning: inspect files and produce a report; do not start browsers unless needed.
- For organizing one live Edge/Chrome profile: generate a candidate plan from an offline copy, then apply it with `chrome.bookmarks` API through a temporary local extension. Avoid raw JSON replacement as the primary path.
- For copying Edge to Chrome or repairing Chrome after sync: compare URL sets first. Prefer add-only or delete/rebuild operations through Chrome's bookmarks API while Chrome sync is online. Raw file patching is a fallback, not the default.
- For restoring from backup: close the browser, copy the selected backup to `Bookmarks`, verify checksum and parseability, start the browser, then re-check after a short sync window.
- For favicon issues: do not promise durable repair by copying or editing `Favicons`. Chrome can overwrite manual SQLite changes from memory. Reliable favicon population usually requires Chrome to load the bookmarked pages.

## Safe Mutation Workflow

Use a temporary MV3 extension for live bookmark mutations:

- `manifest_version: 3`
- `permissions: ["bookmarks"]`
- optional callback host permission such as `http://127.0.0.1:<port>/*`
- background service worker that calls `chrome.bookmarks.getTree`, `getChildren`, `create`, `move`, and `removeTree`
- an execution lock such as `organizePromise` so `onInstalled` and `onStartup` cannot race
- a local callback report with counts, moved nodes, skipped nodes, and errors

Keep mutation conservative:

- Preserve direct bookmark bar URLs when the user wants existing habits kept.
- Move folders across top-level categories only when the category is clearly wrong or the user has authorized broader cleanup.
- Do not merge standalone bookmark bar URLs into folders unless explicitly requested.
- Do not touch mobile/synced roots unless the user specifically asks.
- Avoid broad delete/recreate operations unless fixing a duplicated cloud-synced tree or doing an explicit restore.
- For Chrome sync recovery, clearing and rebuilding the writable desktop roots through the bookmarks API can be safer than repeatedly editing files while Chrome is closed, because the API operation is visible to sync as user intent.

PowerShell launch warning: profile arguments containing spaces must be passed as one quoted argument, for example `--profile-directory="Profile 1" --load-extension="<extDir>" --no-first-run --no-startup-window`. Splitting `--profile-directory=Profile 1` incorrectly can create a wrong profile such as `User Data\Profile`.

## Raw File Fallback

Use raw `Bookmarks` JSON edits only when the browser is closed, a backup exists, and the API/import path is unavailable or unsuitable. After editing:

- Recompute the Chromium bookmark checksum. Edge profiles may include `roots.workspaces_v2`; current Edge files can fail checksum if only `bookmark_bar`, `other`, and `synced` are hashed.
- Preserve existing node shapes and fields where possible. Do not invent unnecessary fields.
- Keep URL identity stable unless the task is a dedupe/delete task.
- Start the browser and re-check after a sync wait, because cloud sync can revert or merge raw file changes.

The fallback is useful for add-only Chrome recovery when the temporary extension cannot be registered, but it is fragile for full-tree replacement under sync.

## Verification

Before reporting success, collect evidence:

- Current file parses as JSON.
- Stored checksum matches the computed checksum when a checksum field exists.
- URL identity is preserved, or all removals are explicitly listed as intended.
- Direct bookmark bar URL sequence is unchanged when requested.
- Top-level and key folder counts match the intended plan.
- Duplicate URL groups are understood: distinguish intentional shortcuts from accidental duplicated trees.
- The browser was restarted or briefly observed when sync could undo the change.
- Temporary extension directories, callback listeners, and tabs created by this task are closed or deliberately retained with a reason.

For cloud bookmark state, there is usually no official direct JSON download. The safest check is a clean temporary profile signed into the same account with bookmark sync enabled, then inspecting/exporting that profile.

## Cleanup And Reporting

Clean only artifacts proven to belong to the current task: temporary extension directories, local callback logs, generated candidate files, and wrongly created profiles caused by this task. Keep backups unless the user explicitly asks to remove rollback points.

Do not delete native browser files such as `Bookmarks.bak`, `Bookmarks.msbak`, extension state, cookies, passwords, or sync data unless the user specifically requests that exact action and the risk is explained.

Final reports should include: backup path, mutation method, verification counts, preserved habits, cleanup performed, backups retained, browser processes/tabs left open, and any remaining sync uncertainty.

## Script

Use `scripts/chromium_bookmarks_audit.mjs` for deterministic read-only evidence:

```bash
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<profile>/Bookmarks" --json
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<profile>/Bookmarks" --baseline "<backup>" --json
```

The script reports root counts, direct bookmark bar URLs, duplicate URL groups, URL set diffs, and checksum status.
