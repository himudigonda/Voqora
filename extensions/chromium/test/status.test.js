import assert from "node:assert/strict";
import { test } from "node:test";

import { ErrorCode, VoqoraError } from "../src/errors.js";
import { Action, badgeText, errorStatus, readingStatus, runAction } from "../src/status.js";

test("readingStatus describes single and multi-part reading", () => {
  assert.deepEqual(readingStatus({ total: 1 }), { kind: "info", text: "Voqora is reading.", badge: "" });
  assert.match(readingStatus({ total: 3 }).text, /3 parts in order/);
  assert.equal(readingStatus({ total: 3 }).badge, "");
});

test("errorStatus exposes the user message and code only", () => {
  const status = errorStatus(new VoqoraError(ErrorCode.unauthorized, "Wrong key"));
  assert.deepEqual(status, { kind: "error", text: "Wrong key", badge: "!", code: "unauthorized" });
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
      return { total: 1 };
    },
    readPage: async (args) => {
      calls.push(["page", args]);
      return { total: 2 };
    },
    stop: async () => calls.push(["stop"]),
  };
  assert.equal((await runAction(reader, { type: Action.readSelection, tabId: 4, selectionText: "x" })).kind, "info");
  assert.match((await runAction(reader, { type: Action.readPage, tabId: 4 })).text, /2 parts/);
  assert.equal((await runAction(reader, { type: Action.stop })).text, "Stopped.");
  await assert.rejects(runAction(reader, { type: "nope" }), TypeError);
  assert.deepEqual(calls, [
    ["selection", { tabId: 4, selectionText: "x" }],
    ["page", { tabId: 4 }],
    ["stop"],
  ]);
});
