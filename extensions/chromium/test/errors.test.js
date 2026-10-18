import assert from "node:assert/strict";
import { test } from "node:test";

import {
  ErrorCode,
  VoqoraError,
  errorFromFetchFailure,
  errorFromResponse,
  retryAfterSeconds,
  userMessage,
} from "../src/errors.js";

test("maps authentication failures to a wrong key message", () => {
  const error = errorFromResponse(401, { error: { message: "Invalid API key." } }, null);
  assert.equal(error.code, ErrorCode.unauthorized);
  assert.match(error.message, /didn't accept the API key/);
});

test("maps rate limits using Retry-After", () => {
  assert.equal(errorFromResponse(429, null, "1").message, "Voqora is busy. Try again in a second.");
  assert.equal(errorFromResponse(429, null, "7").message, "Voqora is busy. Try again in 7 seconds.");
  assert.equal(errorFromResponse(429, null, null).code, ErrorCode.rateLimited);
});

test("retryAfterSeconds clamps bad and huge values", () => {
  assert.equal(retryAfterSeconds(undefined), 1);
  assert.equal(retryAfterSeconds("abc"), 1);
  assert.equal(retryAfterSeconds("0"), 1);
  assert.equal(retryAfterSeconds("99999"), 3600);
  assert.equal(retryAfterSeconds("3"), 3);
});

test("maps 503 to the app not listening", () => {
  const error = errorFromResponse(503, { error: { message: "The Voqora app is not listening." } }, null);
  assert.equal(error.code, ErrorCode.appNotListening);
  assert.match(error.message, /Open Voqora/);
});

test("maps validation errors and includes a short backend message", () => {
  const error = errorFromResponse(400, { error: { message: "text: String should have at least 1 character" } });
  assert.equal(error.code, ErrorCode.invalidRequest);
  assert.equal(error.message, "Voqora couldn't read that text: text: String should have at least 1 character");
  assert.equal(errorFromResponse(400, { error: { message: "x".repeat(400) } }).message, "Voqora couldn't read that text.");
  assert.equal(errorFromResponse(400, "not json").message, "Voqora couldn't read that text.");
});

test("maps the remaining statuses", () => {
  assert.equal(errorFromResponse(403, null).code, ErrorCode.forbidden);
  assert.equal(errorFromResponse(404, null).code, ErrorCode.unsupported);
  assert.equal(errorFromResponse(405, null).code, ErrorCode.unsupported);
  assert.equal(errorFromResponse(413, null).code, ErrorCode.tooLarge);
  assert.equal(errorFromResponse(500, null).code, ErrorCode.serverError);
  assert.equal(errorFromResponse(502, null).code, ErrorCode.serverError);
  assert.equal(errorFromResponse(418, null).message, "Voqora sent an unexpected reply (HTTP 418).");
});

test("maps network failures to unreachable with the port and setup hint", () => {
  const error = errorFromFetchFailure(new TypeError("Failed to fetch"), 51851);
  assert.equal(error.code, ErrorCode.unreachable);
  assert.match(error.message, /port 51851/);
  assert.match(error.message, /Preferences -> Integrations/);
});

test("maps aborts and timeouts to timeout and passes VoqoraErrors through", () => {
  const timeout = new DOMException("timed out", "TimeoutError");
  assert.equal(errorFromFetchFailure(timeout, 1).code, ErrorCode.timeout);
  assert.equal(errorFromFetchFailure(new DOMException("aborted", "AbortError"), 1).code, ErrorCode.timeout);
  const original = new VoqoraError(ErrorCode.tooLarge, "Too large");
  assert.equal(errorFromFetchFailure(original, 1), original);
});

test("userMessage hides unexpected errors", () => {
  assert.equal(userMessage(new Error("secret internals")), "Something went wrong. Try again.");
  assert.equal(userMessage(new VoqoraError(ErrorCode.noSelection, "Select text")), "Select text");
});
