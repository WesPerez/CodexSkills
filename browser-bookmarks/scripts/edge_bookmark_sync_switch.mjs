#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function usage() {
  return [
    "Usage:",
    "  node edge_bookmark_sync_switch.mjs --preferences <Preferences> --inspect",
    "  node edge_bookmark_sync_switch.mjs --preferences <Preferences> --set enabled|disabled --expect enabled|disabled --backup-dir <dir> [--browser edge|chrome]",
    "",
    "The browser must be fully closed for --set. The script changes only sync.bookmarks.",
  ].join("\n");
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--preferences") args.preferences = argv[++i];
    else if (arg === "--inspect") args.inspect = true;
    else if (arg === "--set") args.set = argv[++i];
    else if (arg === "--expect") args.expect = argv[++i];
    else if (arg === "--backup-dir") args.backupDir = argv[++i];
    else if (arg === "--browser") args.browser = argv[++i];
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function stateValue(value, name) {
  if (value === "enabled") return true;
  if (value === "disabled") return false;
  throw new Error(`${name} must be enabled or disabled`);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

class JsonLocator {
  constructor(text) {
    this.text = text;
    this.index = 0;
  }

  parse() {
    if (this.text.charCodeAt(0) === 0xfeff) this.index = 1;
    const node = this.parseValue("$");
    this.skipWhitespace();
    if (this.index !== this.text.length) this.fail("Unexpected trailing content", "$");
    return node;
  }

  fail(message, jsonPath) {
    throw new Error(`${message} at ${jsonPath} (offset ${this.index})`);
  }

  skipWhitespace() {
    while (/[\x20\x09\x0a\x0d]/.test(this.text[this.index] || "")) this.index += 1;
  }

  parseValue(jsonPath) {
    this.skipWhitespace();
    const char = this.text[this.index];
    if (char === "{") return this.parseObject(jsonPath);
    if (char === "[") return this.parseArray(jsonPath);
    if (char === '"') return this.parseString(jsonPath);
    if (this.text.startsWith("true", this.index)) return this.parseLiteral("true", "boolean", true);
    if (this.text.startsWith("false", this.index)) return this.parseLiteral("false", "boolean", false);
    if (this.text.startsWith("null", this.index)) return this.parseLiteral("null", "null", null);
    return this.parseNumber(jsonPath);
  }

  parseLiteral(token, type, value) {
    const start = this.index;
    this.index += token.length;
    return { type, value, start, end: this.index };
  }

  parseString(jsonPath) {
    const start = this.index;
    this.index += 1;
    let escaped = false;
    while (this.index < this.text.length) {
      const char = this.text[this.index];
      if (escaped) {
        escaped = false;
        this.index += 1;
        continue;
      }
      if (char === "\\") {
        escaped = true;
        this.index += 1;
        continue;
      }
      if (char === '"') {
        this.index += 1;
        const raw = this.text.slice(start, this.index);
        let value;
        try {
          value = JSON.parse(raw);
        } catch {
          this.fail("Invalid JSON string", jsonPath);
        }
        return { type: "string", value, start, end: this.index };
      }
      if (char < " ") this.fail("Unescaped control character", jsonPath);
      this.index += 1;
    }
    this.fail("Unterminated JSON string", jsonPath);
  }

  parseNumber(jsonPath) {
    const start = this.index;
    const match = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(this.text.slice(this.index));
    if (!match || match.index !== 0) this.fail("Invalid JSON value", jsonPath);
    this.index += match[0].length;
    return { type: "number", raw: match[0], start, end: this.index };
  }

  parseArray(jsonPath) {
    const start = this.index;
    this.index += 1;
    const items = [];
    this.skipWhitespace();
    if (this.text[this.index] === "]") {
      this.index += 1;
      return { type: "array", items, start, end: this.index };
    }
    let itemIndex = 0;
    while (true) {
      items.push(this.parseValue(`${jsonPath}[${itemIndex}]`));
      itemIndex += 1;
      this.skipWhitespace();
      const char = this.text[this.index];
      if (char === "]") {
        this.index += 1;
        return { type: "array", items, start, end: this.index };
      }
      if (char !== ",") this.fail("Expected comma or closing bracket", jsonPath);
      this.index += 1;
    }
  }

  parseObject(jsonPath) {
    const start = this.index;
    this.index += 1;
    const properties = new Map();
    this.skipWhitespace();
    if (this.text[this.index] === "}") {
      this.index += 1;
      return { type: "object", properties, start, end: this.index };
    }
    while (true) {
      this.skipWhitespace();
      if (this.text[this.index] !== '"') this.fail("Expected object key", jsonPath);
      const keyNode = this.parseString(jsonPath);
      const key = keyNode.value;
      if (properties.has(key)) throw new Error(`Duplicate JSON key ${JSON.stringify(key)} at ${jsonPath}`);
      this.skipWhitespace();
      if (this.text[this.index] !== ":") this.fail("Expected colon", `${jsonPath}.${key}`);
      this.index += 1;
      const valueNode = this.parseValue(`${jsonPath}.${key}`);
      properties.set(key, { keyNode, valueNode });
      this.skipWhitespace();
      const char = this.text[this.index];
      if (char === "}") {
        this.index += 1;
        return { type: "object", properties, start, end: this.index };
      }
      if (char !== ",") this.fail("Expected comma or closing brace", jsonPath);
      this.index += 1;
    }
  }
}

function property(objectNode, name, jsonPath) {
  if (!objectNode || objectNode.type !== "object") throw new Error(`${jsonPath} must be an object`);
  const entry = objectNode.properties.get(name);
  if (!entry) throw new Error(`Missing ${jsonPath}.${name}`);
  return entry.valueNode;
}

export function parsePreferencesState(text) {
  const root = new JsonLocator(text).parse();
  if (root.type !== "object") throw new Error("Preferences root must be an object");
  const sync = property(root, "sync", "$" );
  const bookmarks = property(sync, "bookmarks", "$.sync");
  if (bookmarks.type !== "boolean") throw new Error("$.sync.bookmarks must be boolean");
  const keepEntry = sync.properties.get("keep_everything_synced");
  const keep = keepEntry?.valueNode;
  if (keep && keep.type !== "boolean") throw new Error("$.sync.keep_everything_synced must be boolean");
  return {
    bookmarks: bookmarks.value,
    bookmarksStart: bookmarks.start,
    bookmarksEnd: bookmarks.end,
    keepEverythingSynced: keep ? keep.value : null,
  };
}

export function validateTogglePreconditions(state) {
  if (state.keepEverythingSynced !== false) {
    const value = state.keepEverythingSynced === null ? "missing" : String(state.keepEverythingSynced);
    throw new Error(`sync.keep_everything_synced must be false; current value is ${value}`);
  }
}

export function mutatePreferencesText(text, desired) {
  const before = parsePreferencesState(text);
  const replacement = desired ? "true" : "false";
  const output = text.slice(0, before.bookmarksStart) + replacement + text.slice(before.bookmarksEnd);
  const after = parsePreferencesState(output);
  if (after.bookmarks !== desired) throw new Error("Mutation verification failed");
  if (text.slice(0, before.bookmarksStart) !== output.slice(0, before.bookmarksStart)) {
    throw new Error("Unexpected bytes changed before sync.bookmarks");
  }
  if (text.slice(before.bookmarksEnd) !== output.slice(before.bookmarksStart + replacement.length)) {
    throw new Error("Unexpected bytes changed after sync.bookmarks");
  }
  return { output, before, after };
}

function inferBrowser(preferencesPath, explicit) {
  if (explicit) {
    if (explicit !== "edge" && explicit !== "chrome") throw new Error("--browser must be edge or chrome");
    return explicit;
  }
  const normalized = preferencesPath.replaceAll("/", "\\").toLowerCase();
  if (normalized.includes("\\microsoft\\edge\\user data\\")) return "edge";
  if (normalized.includes("\\google\\chrome\\user data\\")) return "chrome";
  throw new Error("Cannot infer browser from Preferences path; pass --browser edge|chrome");
}

function ensureBrowserClosed(browser) {
  const image = browser === "edge" ? "msedge.exe" : "chrome.exe";
  const result = spawnSync("tasklist.exe", ["/FI", `IMAGENAME eq ${image}`, "/FO", "CSV", "/NH"], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`tasklist failed with exit code ${result.status}`);
  if (new RegExp(`"?${image.replace(".", "\\.")}"?`, "i").test(result.stdout)) {
    throw new Error(`${image} is still running; close all browser and background processes before changing Preferences`);
  }
}

function queryRegistryValue(key, valueName) {
  const result = spawnSync("reg.exe", ["query", key, "/v", valueName], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error) throw result.error;
  return interpretRegistryQuery(result, key, valueName);
}

export function interpretRegistryQuery(result, key, valueName) {
  if (result.status === 1) {
    const detail = `${result.stdout || ""}\n${result.stderr || ""}`;
    if (/unable to find|cannot find|找不到|无法找到/i.test(detail)) return null;
    throw new Error(`reg query could not verify ${key} ${valueName}: ${detail.trim() || "unknown error"}`);
  }
  if (result.status !== 0) throw new Error(`reg query failed for ${key} ${valueName} with exit code ${result.status}`);
  return result.stdout;
}

function ensureNoSyncPolicy(browser) {
  const vendor = browser === "edge" ? "Microsoft\\Edge" : "Google\\Chrome";
  const keys = [`HKCU\\SOFTWARE\\Policies\\${vendor}`, `HKLM\\SOFTWARE\\Policies\\${vendor}`];
  for (const key of keys) {
    const syncDisabled = queryRegistryValue(key, "SyncDisabled");
    if (syncDisabled && /REG_DWORD\s+0x0*1\b/i.test(syncDisabled)) {
      throw new Error(`SyncDisabled policy is enabled at ${key}`);
    }
    for (const valueName of ["SyncTypesListDisabled", "SyncTypesListEnabled"]) {
      const value = queryRegistryValue(key, valueName);
      if (value) throw new Error(`${valueName} policy is present at ${key}; do not override policy-controlled sync types`);
    }
  }
}

function atomicReplace(source, destination) {
  fs.renameSync(source, destination);
}

function writeFileFlushed(file, text, mode) {
  const descriptor = fs.openSync(file, "wx", mode);
  try {
    fs.writeFileSync(descriptor, text, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function uniqueArtifactPath(directory, stem, extension) {
  const timestamp = new Date().toISOString().replaceAll(":", "-");
  for (let suffix = 0; suffix < 1000; suffix += 1) {
    const discriminator = suffix === 0 ? "" : `-${suffix}`;
    const candidate = path.join(directory, `${stem}-${timestamp}${discriminator}${extension}`);
    if (!fs.existsSync(candidate)) return candidate;
  }
  throw new Error(`Cannot allocate a unique artifact path in ${directory}`);
}

export function applyMutation({
  preferences,
  desired,
  expected,
  backupDir,
  browser,
  enforceRuntimeGuards = true,
  runtimeGuards = { ensureBrowserClosed, ensureNoSyncPolicy },
}) {
  const target = path.resolve(preferences);
  const lockFile = `${target}.codex-bookmark-sync.lock`;
  let lockDescriptor;
  try {
    lockDescriptor = fs.openSync(lockFile, "wx");
  } catch (error) {
    if (error?.code === "EEXIST") throw new Error(`Bookmark sync mutation lock already exists: ${lockFile}`);
    throw error;
  }
  try {
  const original = fs.readFileSync(target, "utf8");
  const state = parsePreferencesState(original);
  validateTogglePreconditions(state);
  if (state.bookmarks !== expected) {
    throw new Error(`Expected sync.bookmarks=${expected}, found ${state.bookmarks}`);
  }
  if (state.bookmarks === desired) {
    return {
      preferences: target,
      changed: false,
      before: state.bookmarks,
      after: state.bookmarks,
      engineTransitionVerified: false,
    };
  }

  const resolvedBrowser = browser || (enforceRuntimeGuards ? inferBrowser(target) : null);
  if (enforceRuntimeGuards) {
    runtimeGuards.ensureBrowserClosed(resolvedBrowser);
    runtimeGuards.ensureNoSyncPolicy(resolvedBrowser);
  }

  const backupRoot = path.resolve(backupDir);
  fs.mkdirSync(backupRoot, { recursive: true });
  const originalHash = sha256(Buffer.from(original, "utf8"));
  const backupFile = uniqueArtifactPath(
    backupRoot,
    `Preferences.before-bookmark-sync-${originalHash.slice(0, 12)}`,
    ".json",
  );
  fs.copyFileSync(target, backupFile, fs.constants.COPYFILE_EXCL);
  if (sha256(fs.readFileSync(backupFile)) !== originalHash) throw new Error("Preferences backup hash mismatch");

  const mutation = mutatePreferencesText(original, desired);
  const tempFile = `${target}.codex-${process.pid}-${Date.now()}.tmp`;
  const mode = fs.statSync(target).mode;
  try {
    writeFileFlushed(tempFile, mutation.output, mode);
    if (enforceRuntimeGuards) runtimeGuards.ensureBrowserClosed(resolvedBrowser);
    const currentHash = sha256(fs.readFileSync(target));
    if (currentHash !== originalHash) {
      throw new Error("Preferences changed after inspection; refusing to overwrite a newer file");
    }
    atomicReplace(tempFile, target);
  } finally {
    if (fs.existsSync(tempFile)) fs.rmSync(tempFile, { force: true });
  }

  const finalText = fs.readFileSync(target, "utf8");
  const finalState = parsePreferencesState(finalText);
  if (finalState.bookmarks !== desired) throw new Error("Preferences reread did not preserve requested state");
  if (finalText !== mutation.output) throw new Error("Preferences reread differs from the verified mutation output");

  const finalHash = sha256(Buffer.from(finalText, "utf8"));
  const manifestFile = uniqueArtifactPath(backupRoot, "bookmark-sync-switch", ".json");
  const manifest = {
    preferences: target,
    browser: resolvedBrowser,
    changed: true,
    before: state.bookmarks,
    after: desired,
    keepEverythingSynced: state.keepEverythingSynced,
    backup: backupFile,
    beforeSha256: originalHash,
    afterSha256: finalHash,
    targetTokenStart: state.bookmarksStart,
    targetTokenEndBefore: state.bookmarksEnd,
    otherBytesUnchanged: true,
    engineTransitionVerified: false,
  };
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
  return { ...manifest, manifest: manifestFile };
  } finally {
    fs.closeSync(lockDescriptor);
    fs.rmSync(lockFile, { force: true });
  }
}

function inspect(preferences) {
  const target = path.resolve(preferences);
  const text = fs.readFileSync(target, "utf8");
  const state = parsePreferencesState(text);
  return {
    preferences: target,
    syncBookmarks: state.bookmarks,
    keepEverythingSynced: state.keepEverythingSynced,
    sha256: sha256(Buffer.from(text, "utf8")),
  };
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(usage());
    return;
  }
  if (!args.preferences) throw new Error("--preferences is required");
  if (args.inspect && args.set) throw new Error("Choose --inspect or --set, not both");
  if (args.inspect) {
    console.log(JSON.stringify(inspect(args.preferences), null, 2));
    return;
  }
  if (!args.set) throw new Error("--set is required when --inspect is not used");
  if (!args.expect) throw new Error("--expect is required for --set");
  if (!args.backupDir) throw new Error("--backup-dir is required for --set");
  const desired = stateValue(args.set, "--set");
  const expected = stateValue(args.expect, "--expect");
  const browser = inferBrowser(path.resolve(args.preferences), args.browser);
  const result = applyMutation({
    preferences: args.preferences,
    desired,
    expected,
    backupDir: args.backupDir,
    browser,
  });
  console.log(JSON.stringify(result, null, 2));
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
