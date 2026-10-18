import assert from "node:assert/strict";
import { test } from "node:test";

import { MAX_SPEAK_CHARS } from "../src/config.js";
import { ErrorCode, VoqoraError } from "../src/errors.js";
import { SESSION_KEY, createReader } from "../src/reader.js";
import { MemoryArea, VALID_KEY } from "./helpers/fakes.js";

function setup({ settings = { port: 51851, apiKey: VALID_KEY }, selection = "", page = "", speakError = null } = {}) {
  const spoken = [];
  const stops = [];
  const clients = [];
  const settingsArea = new MemoryArea(settings);
  const sessionArea = new MemoryArea();
  const reader = createReader({
    settingsArea,
    sessionArea,
    createClient: (resolved) => {
      clients.push(resolved);
      return {
        speak: async (text) => {
          if (speakError) {
            throw speakError;
          }
          spoken.push(text);
          return `id-${spoken.length}`;
        },
        stop: async () => {
          stops.push(true);
          return "stop";
        },
      };
    },
    pageAccess: {
      selection: async () => selection,
      pageText: async () => page,
    },
  });
  return { reader, spoken, stops, clients, sessionArea };
}

test("reads the context menu selection without touching the page", async () => {
  const { reader, spoken, clients } = setup({ selection: "page selection" });
  assert.deepEqual(await reader.readSelection({ tabId: 1, selectionText: "  menu text " }), { part: 1, total: 1 });
  assert.deepEqual(spoken, ["menu text"]);
  assert.deepEqual(clients, [{ port: 51851, apiKey: VALID_KEY }]);
});

test("falls back to the page selection and reports an empty selection", async () => {
  const withPage = setup({ selection: "from page" });
  await withPage.reader.readSelection({ tabId: 3 });
  assert.deepEqual(withPage.spoken, ["from page"]);

  const empty = setup({ selection: "   " });
  await assert.rejects(empty.reader.readSelection({ tabId: 3 }), { code: ErrorCode.noSelection });
  await assert.rejects(empty.reader.readSelection(), { code: ErrorCode.noSelection });
  assert.deepEqual(empty.spoken, []);
});

test("requires settings before speaking", async () => {
  const { reader, spoken } = setup({ settings: {}, selection: "text" });
  await assert.rejects(reader.readSelection({ tabId: 1 }), { code: ErrorCode.notConfigured });
  assert.deepEqual(spoken, []);
});

test("reads a short page in one request and keeps no session", async () => {
  const { reader, spoken, sessionArea } = setup({ page: "Readable page text." });
  assert.deepEqual(await reader.readPage({ tabId: 2 }), { part: 1, total: 1 });
  assert.deepEqual(spoken, ["Readable page text."]);
  assert.equal(sessionArea.data[SESSION_KEY], undefined);
  assert.equal(await reader.currentProgress(), null);
});

test("reports a page with no readable text", async () => {
  const { reader } = setup({ page: "  " });
  await assert.rejects(reader.readPage({ tabId: 2 }), { code: ErrorCode.noPageText });
});

test("reads a long page part by part", async () => {
  const paragraph = `${"word ".repeat(9000).trim()}.`;
  const page = [paragraph, paragraph, paragraph].join("\n\n");
  const { reader, spoken } = setup({ page });
  assert.deepEqual(await reader.readPage({ tabId: 2 }), { part: 1, total: 3 });
  assert.deepEqual(await reader.currentProgress(), { part: 1, total: 3 });
  assert.deepEqual(await reader.readNextPart(), { part: 2, total: 3 });
  assert.deepEqual(await reader.readNextPart(), { part: 3, total: 3 });
  assert.equal(await reader.currentProgress(), null);
  assert.equal(await reader.readNextPart(), null);
  assert.equal(spoken.length, 3);
  for (const part of spoken) {
    assert.ok(part.length <= MAX_SPEAK_CHARS);
    assert.equal(part, paragraph);
  }
});

test("a failed speak keeps no new session", async () => {
  const { reader, sessionArea } = setup({
    page: `${"a ".repeat(30000)}\n\n${"b ".repeat(30000)}`,
    speakError: new VoqoraError(ErrorCode.appNotListening, "not listening"),
  });
  await assert.rejects(reader.readPage({ tabId: 1 }), { code: ErrorCode.appNotListening });
  assert.equal(sessionArea.data[SESSION_KEY], undefined);
});

test("stop clears the session and tells Voqora to stop", async () => {
  const { reader, stops } = setup({ page: `${"a ".repeat(30000)}\n\n${"b ".repeat(30000)}` });
  await reader.readPage({ tabId: 1 });
  assert.notEqual(await reader.currentProgress(), null);
  await reader.stop();
  assert.equal(stops.length, 1);
  assert.equal(await reader.currentProgress(), null);
});

test("ignores a corrupted session", async () => {
  const { reader, sessionArea } = setup();
  sessionArea.data[SESSION_KEY] = { parts: ["a", 5], index: 0 };
  assert.equal(await reader.currentProgress(), null);
  sessionArea.data[SESSION_KEY] = { parts: ["a", "b"], index: 4 };
  assert.equal(await reader.readNextPart(), null);
});
