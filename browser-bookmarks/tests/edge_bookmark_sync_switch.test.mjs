import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  applyMutation,
  interpretRegistryQuery,
  mutatePreferencesText,
  parsePreferencesState,
  validateTogglePreconditions,
} from "../scripts/edge_bookmark_sync_switch.mjs";

const fixture = '{"sync":{"bookmarks":false,"keep_everything_synced":false},"other":{"bookmarks":true,"big":900719925474099312345,"text":"中文\\u4e2d"}}';

test("locates only root sync.bookmarks", () => {
  const state = parsePreferencesState(fixture);
  assert.equal(state.bookmarks, false);
  assert.equal(state.keepEverythingSynced, false);
});

test("changes only the boolean token and preserves large integers and Unicode bytes", () => {
  const result = mutatePreferencesText(fixture, true);
  assert.equal(parsePreferencesState(result.output).bookmarks, true);
  assert.match(result.output, /900719925474099312345/);
  assert.match(result.output, /中文\\u4e2d/);
  assert.equal(result.output, fixture.replace('"bookmarks":false', '"bookmarks":true'));
});

test("supports true to false", () => {
  const enabled = fixture.replace('"bookmarks":false', '"bookmarks":true');
  const result = mutatePreferencesText(enabled, false);
  assert.equal(result.output, fixture);
});

test("rejects duplicate keys and malformed JSON", () => {
  assert.throws(
    () => parsePreferencesState('{"sync":{"bookmarks":true,"bookmarks":false,"keep_everything_synced":false}}'),
    /Duplicate JSON key/,
  );
  assert.throws(() => parsePreferencesState('{"sync":'), /Invalid JSON value|Unexpected/);
});

test("rejects missing, non-boolean, and keep-all states", () => {
  assert.throws(() => parsePreferencesState('{"sync":{"keep_everything_synced":false}}'), /Missing/);
  assert.throws(
    () => parsePreferencesState('{"sync":{"bookmarks":"true","keep_everything_synced":false}}'),
    /must be boolean/,
  );
  const state = parsePreferencesState('{"sync":{"bookmarks":true,"keep_everything_synced":true}}');
  assert.throws(() => validateTogglePreconditions(state), /must be false/);
});

test("applies a fixture mutation with backup, manifest, and stale-value protection", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bookmark-sync-switch-"));
  try {
    const preferences = path.join(root, "Preferences");
    const backupDir = path.join(root, "backup");
    fs.writeFileSync(preferences, fixture, "utf8");
    const result = applyMutation({
      preferences,
      desired: true,
      expected: false,
      backupDir,
      enforceRuntimeGuards: false,
    });
    assert.equal(result.changed, true);
    assert.equal(parsePreferencesState(fs.readFileSync(preferences, "utf8")).bookmarks, true);
    assert.equal(fs.readFileSync(result.backup, "utf8"), fixture);
    assert.equal(JSON.parse(fs.readFileSync(result.manifest, "utf8")).otherBytesUnchanged, true);
    const enabledText = fs.readFileSync(preferences, "utf8");
    assert.throws(
      () => applyMutation({
        preferences,
        desired: false,
        expected: false,
        backupDir,
        enforceRuntimeGuards: false,
      }),
      /Expected sync.bookmarks=false, found true/,
    );
    const second = applyMutation({
      preferences,
      desired: false,
      expected: true,
      backupDir,
      enforceRuntimeGuards: false,
    });
    assert.equal(second.changed, true);
    assert.notEqual(second.backup, result.backup);
    assert.equal(fs.readFileSync(second.backup, "utf8"), enabledText);
    assert.equal(parsePreferencesState(fs.readFileSync(preferences, "utf8")).bookmarks, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refuses a concurrent mutation lock without deleting it", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bookmark-sync-lock-"));
  try {
    const preferences = path.join(root, "Preferences");
    const lock = `${preferences}.codex-bookmark-sync.lock`;
    fs.writeFileSync(preferences, fixture, "utf8");
    fs.writeFileSync(lock, "owned elsewhere", "utf8");
    assert.throws(
      () => applyMutation({
        preferences,
        desired: true,
        expected: false,
        backupDir: path.join(root, "backup"),
        enforceRuntimeGuards: false,
      }),
      /mutation lock already exists/,
    );
    assert.equal(fs.readFileSync(lock, "utf8"), "owned elsewhere");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed for registry query errors but accepts a missing value", () => {
  assert.equal(
    interpretRegistryQuery({ status: 1, stdout: "", stderr: "ERROR: The system was unable to find the specified registry key or value." }, "HKCU\\x", "SyncDisabled"),
    null,
  );
  assert.throws(
    () => interpretRegistryQuery({ status: 1, stdout: "", stderr: "ERROR: Access is denied." }, "HKLM\\x", "SyncDisabled"),
    /could not verify/,
  );
  assert.throws(
    () => interpretRegistryQuery({ status: 2, stdout: "", stderr: "bad" }, "HKLM\\x", "SyncDisabled"),
    /exit code 2/,
  );
});

test("runs the browser guard twice and refuses a file changed before replace", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bookmark-sync-race-"));
  try {
    const preferences = path.join(root, "Preferences");
    fs.writeFileSync(preferences, fixture, "utf8");
    let browserChecks = 0;
    let policyChecks = 0;
    const externallyChanged = `${fixture}\n`;
    assert.throws(
      () => applyMutation({
        preferences,
        desired: true,
        expected: false,
        backupDir: path.join(root, "backup"),
        browser: "edge",
        runtimeGuards: {
          ensureBrowserClosed() {
            browserChecks += 1;
            if (browserChecks === 2) fs.writeFileSync(preferences, externallyChanged, "utf8");
          },
          ensureNoSyncPolicy() {
            policyChecks += 1;
          },
        },
      }),
      /refusing to overwrite a newer file/,
    );
    assert.equal(browserChecks, 2);
    assert.equal(policyChecks, 1);
    assert.equal(fs.readFileSync(preferences, "utf8"), externallyChanged);
    assert.equal(fs.existsSync(`${preferences}.codex-bookmark-sync.lock`), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
