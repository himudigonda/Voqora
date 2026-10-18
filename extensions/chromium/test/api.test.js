import assert from "node:assert/strict";
import { test } from "node:test";

import { createVoqoraClient } from "../src/api.js";
import { ErrorCode } from "../src/errors.js";
import { VALID_KEY, jsonResponse, recordingFetch } from "./helpers/fakes.js";

function client(responder) {
  const recorder = recordingFetch(responder);
  return { ...recorder, api: createVoqoraClient({ port: 51851, apiKey: VALID_KEY, fetchImpl: recorder.fetchImpl }) };
}

test("listModels sends the bearer key and returns model ids", async () => {
  const { api, calls } = client(() =>
    jsonResponse(200, { object: "list", data: [{ id: "kokoro" }, { id: "tts-1" }, { nope: true }] }),
  );
  assert.deepEqual(await api.listModels(), ["kokoro", "tts-1"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://127.0.0.1:51851/v1/models");
  assert.equal(calls[0].init.method, "GET");
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${VALID_KEY}`);
  assert.equal(calls[0].init.credentials, "omit");
  assert.equal(calls[0].init.body, undefined);
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});

test("listModels rejects a server that is not the local API", async () => {
  const { api } = client(() => jsonResponse(200, { hello: "world" }));
  await assert.rejects(api.listModels(), { code: ErrorCode.unexpectedResponse });
});

test("speak posts JSON text and returns the queued id", async () => {
  const { api, calls } = client(() => jsonResponse(202, { status: "queued", id: "evt-1" }));
  assert.equal(await api.speak("Hello there."), "evt-1");
  assert.equal(calls[0].url, "http://127.0.0.1:51851/v1/voqora/speak");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(calls[0].init.body), { text: "Hello there." });
});

test("speak validates text before any request", async () => {
  const { api, calls } = client(() => jsonResponse(202, { status: "queued", id: "x" }));
  await assert.rejects(api.speak("   "), { code: ErrorCode.invalidRequest });
  await assert.rejects(api.speak("a".repeat(50001)), { code: ErrorCode.tooLarge });
  assert.equal(calls.length, 0);
});

test("stop posts without a body", async () => {
  const { api, calls } = client(() => jsonResponse(202, { status: "queued", id: "stop-1" }));
  assert.equal(await api.stop(), "stop-1");
  assert.equal(calls[0].url, "http://127.0.0.1:51851/v1/voqora/stop");
  assert.equal(calls[0].init.body, undefined);
  assert.equal(calls[0].init.headers["Content-Type"], undefined);
});

test("maps HTTP errors with their bodies and headers", async () => {
  const unauthorized = client(() =>
    jsonResponse(401, { error: { message: "Invalid API key.", type: "authentication_error" } }),
  );
  await assert.rejects(unauthorized.api.speak("Hi"), { code: ErrorCode.unauthorized });

  const limited = client(() => jsonResponse(429, { error: { message: "slow down" } }, { "Retry-After": "5" }));
  await assert.rejects(limited.api.speak("Hi"), { message: "Voqora is busy. Try again in 5 seconds." });

  const notListening = client(() => jsonResponse(503, { error: { message: "not listening" } }));
  await assert.rejects(notListening.api.stop(), { code: ErrorCode.appNotListening });

  const htmlError = client(() => new Response("<html>oops</html>", { status: 500 }));
  await assert.rejects(htmlError.api.stop(), { code: ErrorCode.serverError });
});

test("rejects a success reply without a queued id", async () => {
  const { api } = client(() => jsonResponse(200, { status: "ok" }));
  await assert.rejects(api.speak("Hi"), { code: ErrorCode.unexpectedResponse });
});

test("maps connection failures and timeouts", async () => {
  const refused = client(() => {
    throw new TypeError("Failed to fetch");
  });
  await assert.rejects(refused.api.listModels(), { code: ErrorCode.unreachable });

  const slow = client((_url, init) => {
    assert.ok(init.signal instanceof AbortSignal);
    throw new DOMException("The operation timed out.", "TimeoutError");
  });
  await assert.rejects(slow.api.listModels(), { code: ErrorCode.timeout });
});
