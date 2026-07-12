import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const script = path.resolve(testDirectory, "../scripts/chromium_bookmarks_audit.mjs");

test("redacts raw URLs and emits file and semantic tree hashes", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bookmarks-audit-"));
  try {
    const bookmarks = path.join(root, "Bookmarks");
    const secretUrl = "https://user:password@example.test/path?token=secret-value";
    const fixture = {
      checksum: "not-a-real-checksum",
      roots: {
        bookmark_bar: {
          id: "1",
          name: "Bookmarks bar",
          type: "folder",
          children: [{ id: "2", name: "Private", type: "url", url: secretUrl }],
        },
      },
      version: 1,
    };
    fs.writeFileSync(bookmarks, JSON.stringify(fixture), "utf8");
    const result = spawnSync(process.execPath, [script, "--bookmarks", bookmarks, "--json"], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /secret-value|user:password|example\.test/);
    const report = JSON.parse(result.stdout);
    assert.match(report.current.fileSha256, /^[a-f0-9]{64}$/);
    assert.match(report.current.treeSignatureSha256, /^[a-f0-9]{64}$/);
    assert.match(report.current.topLevelBookmarkBar[0].url, /^<url scheme=https len=\d+ sha256=[a-f0-9]{16}>$/);
    assert.equal("treeSignature" in report.current, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
