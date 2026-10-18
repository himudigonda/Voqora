import assert from "node:assert/strict";
import { test } from "node:test";

import { ErrorCode, VoqoraError } from "../src/errors.js";
import { Action, badgeText, errorStatus, idleStatus, readingStatus, runAction } from "../src/status.js";

test("readingStatus describes single and multi-part reading", () => {
  assert.deepEqual(readingStatus({ part: 1, total: 1 }), {
    kind: "info",
    text: "Voqora is reading.",
    badge: "",
    progress: null,
  });
  const first = readingStatus({ part: 1, total: 3 });
  assert.equal(first.badge, "1/3");
  assert.deepEqual(first.progress, { part: 1, total: 3 });
  assert.match(first.text, /part 1 of 3/);
  const last = readingStatus({ part: 3, total: 3 });
  assert.equal(last.badge, "");
  assert.equal(last.progress, null);
});

test("idleStatus only reports unfinished sessions", () => {
  assert.equal(idleStatus(null).kind, "idle");
  assert.equal(idleStatus({ part: 2, total: 2 }).kind, "idle");
  assert.equal(idleStatus({ part: 1, total: 2 }).badge, "1/2");
});

test("errorStatus exposes the user message and code only", () => {
  const status = errorStatus(new VoqoraError(ErrorCode.unauthorized, "Wrong key"));
  assert.deepEqual(status, { kind: "error", text: "Wrong key", badge: "!", code: "unauthorized", progress: null });
  assert.equal(errorStatus(new Error("boom")).text, "Something went wrong. Try again.");
});

test("badgeText fits the toolbar badge", () => {
  assert.equal(badgeText("12/34"), "12/3");
  assert.equal(badgeText(undefined), "");
});

test("runAction dispatches to the reader", async () => {
  const calls = [];
  const reader = {
    readSelection: async (args) => {
      calls.push(["selection", args]);
      return { part: 1, total: 1 };
    },
    readPage: async (args) => {
      calls.push(["page", args]);
      return { part: 1, total: 2 };
    },
    readNextPart: async () => null,
    stop: async () => calls.push(["stop"]),
    currentProgress: async () => ({ part: 1, total: 2 }),
  };
  assert.equal((await runAction(reader, { type: Action.readSelection, tabId: 4, selectionText: "x" })).kind, "info");
  assert.equal((await runAction(reader, { type: Action.readPage, tabId: 4 })).badge, "1/2");
  assert.equal((await runAction(reader, { type: Action.readNextPart })).kind, "idle");
  assert.equal((await runAction(reader, { type: Action.stop })).text, "Stopped.");
  assert.equal((await runAction(reader, { type: Action.progress })).badge, "1/2");
  await assert.rejects(runAction(reader, { type: "nope" }), TypeError);
  assert.deepEqual(calls, [
    ["selection", { tabId: 4, selectionText: "x" }],
    ["page", { tabId: 4 }],
    ["stop"],
  ]);
});
