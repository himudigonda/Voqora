import assert from "node:assert/strict";
import { test } from "node:test";

import { DEFAULT_PORT, endpointUrl, parseApiKey, parsePort, parseSettings } from "../src/config.js";
import { VALID_KEY } from "./helpers/fakes.js";

test("parsePort accepts ports in range and trims whitespace", () => {
  assert.deepEqual(parsePort(" 51851 "), { ok: true, value: 51851 });
  assert.deepEqual(parsePort(1024), { ok: true, value: 1024 });
  assert.deepEqual(parsePort("65535"), { ok: true, value: 65535 });
});

test("parsePort rejects out of range, fractional and non-numeric values", () => {
  for (const value of ["1023", "65536", "80", "51851.5", "-1", "abc", "", null, undefined, "1e4", "123456"]) {
    const result = parsePort(value);
    assert.equal(result.ok, false, `expected ${value} to be rejected`);
    assert.equal(result.message, "Enter a port from 1024 to 65535.");
  }
});

test("parseApiKey enforces length and the backend character set", () => {
  assert.deepEqual(parseApiKey(`  ${VALID_KEY}  `), { ok: true, value: VALID_KEY });
  assert.equal(parseApiKey("a".repeat(32)).ok, true);
  assert.equal(parseApiKey("a".repeat(128)).ok, true);
  assert.equal(parseApiKey("a".repeat(31)).ok, false);
  assert.equal(parseApiKey("a".repeat(129)).ok, false);
  assert.equal(parseApiKey(`${"a".repeat(32)} b`).ok, false);
  assert.equal(parseApiKey(`${"a".repeat(32)}!`).ok, false);
  assert.match(parseApiKey("").message, /Preferences -> Integrations/);
});

test("parseSettings reports the first invalid field", () => {
  assert.deepEqual(parseSettings({ port: "70000", apiKey: VALID_KEY }).field, "port");
  assert.deepEqual(parseSettings({ port: DEFAULT_PORT, apiKey: "short" }).field, "apiKey");
  assert.deepEqual(parseSettings({ port: "51851", apiKey: VALID_KEY }), {
    ok: true,
    value: { port: 51851, apiKey: VALID_KEY },
  });
  assert.equal(parseSettings(undefined).ok, false);
});

test("endpointUrl always targets 127.0.0.1 and validates its inputs", () => {
  assert.equal(endpointUrl(51851, "/v1/models"), "http://127.0.0.1:51851/v1/models");
  assert.equal(endpointUrl("2000", "/v1/voqora/speak"), "http://127.0.0.1:2000/v1/voqora/speak");
  assert.throws(() => endpointUrl(80, "/v1/models"), RangeError);
  assert.throws(() => endpointUrl(51851, "//evil.example/v1"), TypeError);
  assert.throws(() => endpointUrl(51851, "/integrations/local-api"), TypeError);
});
