import assert from "node:assert/strict";
import { test } from "node:test";

import { DEFAULT_PORT } from "../src/config.js";
import { ErrorCode } from "../src/errors.js";
import { loadSettings, requireSettings, saveSettings } from "../src/settings.js";
import { ariaKeyShortcut } from "../src/shortcuts.js";
import { MemoryArea, VALID_KEY } from "./helpers/fakes.js";

test("loadSettings falls back to the default port and an empty key", async () => {
  assert.deepEqual(await loadSettings(new MemoryArea()), { port: DEFAULT_PORT, apiKey: "" });
  assert.deepEqual(await loadSettings(new MemoryArea({ port: "bad", apiKey: 42 })), { port: DEFAULT_PORT, apiKey: "" });
});

test("saveSettings stores only validated values", async () => {
  const area = new MemoryArea();
  const rejected = await saveSettings(area, { port: "80", apiKey: VALID_KEY });
  assert.equal(rejected.ok, false);
  assert.deepEqual(area.data, {});
  const saved = await saveSettings(area, { port: " 6000 ", apiKey: ` ${VALID_KEY} ` });
  assert.equal(saved.ok, true);
  assert.deepEqual(area.data, { port: 6000, apiKey: VALID_KEY });
});

test("requireSettings throws a setup error until a key is saved", async () => {
  await assert.rejects(requireSettings(new MemoryArea()), { code: ErrorCode.notConfigured });
  assert.deepEqual(await requireSettings(new MemoryArea({ apiKey: VALID_KEY })), {
    port: DEFAULT_PORT,
    apiKey: VALID_KEY,
  });
});

test("ariaKeyShortcut converts browser shortcut labels", () => {
  assert.equal(ariaKeyShortcut("Alt+Shift+R"), "Alt+Shift+R");
  assert.equal(ariaKeyShortcut("Ctrl+Shift+S"), "Control+Shift+S");
  assert.equal(ariaKeyShortcut("⌥⇧R"), "Alt+Shift+R");
  assert.equal(ariaKeyShortcut("⌘⌃S"), "Meta+Control+S");
  assert.equal(ariaKeyShortcut(""), "");
});
