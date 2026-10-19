import assert from "node:assert/strict";
import { test } from "node:test";

import { MAX_SPEAK_CHARS } from "../src/config.js";
import { ErrorCode, VoqoraError } from "../src/errors.js";
import { createReader } from "../src/reader.js";
import { MemoryArea, VALID_KEY } from "./helpers/fakes.js";

function setup({ settings = { port: 51851, apiKey: VALID_KEY }, selection = "", page = "", speakError = null, failOnCall = null } = {}) {
  const spoken = [];
  const stops = [];
  const clients = [];
  const reader = createReader({
    settingsArea: new MemoryArea(settings),
    createClient: (resolved) => {
      clients.push(resolved);
      return {
        speak: async (text, mode) => {
          if (speakError && (failOnCall === null || spoken.length === failOnCall)) {
            throw speakError;
          }
          spoken.push({ text, mode });
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
  return { reader, spoken, stops, clients };
}

test("reads the context menu selection without touching the page", async () => {
  const { reader, spoken, clients } = setup({ selection: "page selection" });
  assert.deepEqual(await reader.readSelection({ tabId: 1, selectionText: "  menu text " }), { total: 1 });
  assert.deepEqual(spoken, [{ text: "menu text", mode: "replace" }]);
  assert.deepEqual(clients, [{ port: 51851, apiKey: VALID_KEY }]);
});

test("falls back to the page selection and reports an empty selection", async () => {
  const withPage = setup({ selection: "from page" });
  await withPage.reader.readSelection({ tabId: 3 });
  assert.deepEqual(withPage.spoken, [{ text: "from page", mode: "replace" }]);

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

test("reads a short page in one replacing request", async () => {
  const { reader, spoken } = setup({ page: "Readable page text." });
  assert.deepEqual(await reader.readPage({ tabId: 2 }), { total: 1 });
  assert.deepEqual(spoken, [{ text: "Readable page text.", mode: "replace" }]);
});

test("reports a page with no readable text", async () => {
  const { reader } = setup({ page: "  " });
  await assert.rejects(reader.readPage({ tabId: 2 }), { code: ErrorCode.noPageText });
});

test("sends every part of a long page, the first replacing and the rest queued", async () => {
  const paragraph = `${"word ".repeat(9000).trim()}.`;
  const page = [paragraph, paragraph, paragraph].join("\n\n");
  const { reader, spoken } = setup({ page });
  assert.deepEqual(await reader.readPage({ tabId: 2 }), { total: 3 });
  assert.deepEqual(spoken.map((request) => request.mode), ["replace", "queue", "queue"]);
  for (const { text } of spoken) {
    assert.ok(text.length <= MAX_SPEAK_CHARS);
    assert.equal(text, paragraph);
  }
});

test("a failure on a later part is reported", async () => {
  const { reader, spoken } = setup({
    page: `${"a ".repeat(30000)}\n\n${"b ".repeat(30000)}`,
    speakError: new VoqoraError(ErrorCode.rateLimited, "busy"),
    failOnCall: 1,
  });
  await assert.rejects(reader.readPage({ tabId: 1 }), { code: ErrorCode.rateLimited });
  assert.equal(spoken.length, 1);
});

test("a failed first part sends nothing more", async () => {
  const { reader, spoken } = setup({
    page: `${"a ".repeat(30000)}\n\n${"b ".repeat(30000)}`,
    speakError: new VoqoraError(ErrorCode.appNotListening, "not listening"),
  });
  await assert.rejects(reader.readPage({ tabId: 1 }), { code: ErrorCode.appNotListening });
  assert.deepEqual(spoken, []);
});

test("stop tells Voqora to stop", async () => {
  const { reader, stops } = setup();
  await reader.stop();
  assert.equal(stops.length, 1);
});
