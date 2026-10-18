import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const manifest = JSON.parse(readFileSync(`${root}manifest.json`, "utf8"));

test("uses Manifest V3 with a module service worker", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.type, "module");
});

test("asks only for the minimal permissions", () => {
  assert.deepEqual([...manifest.permissions].sort(), ["activeTab", "contextMenus", "scripting", "storage"]);
  assert.deepEqual(manifest.host_permissions, ["http://127.0.0.1/*"]);
  assert.equal(manifest.content_scripts, undefined);
  assert.equal(manifest.web_accessible_resources, undefined);
  assert.equal(manifest.externally_connectable, undefined);
});

test("declares the keyboard shortcuts", () => {
  assert.equal(manifest.commands["read-selection"].suggested_key.default, "Alt+Shift+R");
  assert.equal(manifest.commands["stop-reading"].suggested_key.default, "Alt+Shift+S");
});

test("every referenced file exists", () => {
  const files = [
    manifest.background.service_worker,
    manifest.action.default_popup,
    manifest.options_ui.page,
    ...Object.values(manifest.icons),
    ...Object.values(manifest.action.default_icon),
    "src/page-text.js",
  ];
  for (const file of files) {
    assert.ok(existsSync(`${root}${file}`), `${file} is missing`);
  }
});

test("restricts extension page connections to this Mac", () => {
  const policy = manifest.content_security_policy.extension_pages;
  assert.match(policy, /script-src 'self'/);
  assert.match(policy, /connect-src http:\/\/127\.0\.0\.1:\*/);
});
