import assert from "node:assert/strict";
import { test } from "node:test";

import { splitIntoChunks } from "../src/chunking.js";
import { MAX_SPEAK_CHARS } from "../src/config.js";

test("returns one trimmed chunk for short text and none for blank text", () => {
  assert.deepEqual(splitIntoChunks("  Hello world.  "), ["Hello world."]);
  assert.deepEqual(splitIntoChunks("   \n  "), []);
  assert.deepEqual(splitIntoChunks(undefined), []);
});

test("keeps text exactly at the limit in one chunk", () => {
  const text = "a".repeat(MAX_SPEAK_CHARS);
  assert.deepEqual(splitIntoChunks(text), [text]);
});

test("prefers paragraph boundaries", () => {
  const first = "First paragraph sentence one. Sentence two.";
  const second = "Second paragraph.";
  const chunks = splitIntoChunks(`${first}\n\n${second}`, 50);
  assert.deepEqual(chunks, [first, second]);
});

test("falls back to sentence boundaries inside a long paragraph", () => {
  const text = "One two three four. Five six seven eight. Nine ten eleven twelve.";
  const chunks = splitIntoChunks(text, 45);
  assert.deepEqual(chunks, ["One two three four. Five six seven eight.", "Nine ten eleven twelve."]);
});

test("falls back to word boundaries and then hard cuts", () => {
  assert.deepEqual(splitIntoChunks("alpha beta gamma delta", 12), ["alpha beta", "gamma delta"]);
  assert.deepEqual(splitIntoChunks("abcdefghij", 4), ["abcd", "efgh", "ij"]);
});

test("never splits a surrogate pair on a hard cut", () => {
  const chunks = splitIntoChunks("abc😀def", 4);
  assert.deepEqual(chunks, ["abc", "😀de", "f"]);
  for (const chunk of chunks) {
    assert.ok(chunk.length <= 4);
    assert.equal(chunk.isWellFormed(), true);
  }
});

test("every chunk stays under the limit and nothing is lost", () => {
  const paragraph = "Voqora reads text aloud, sentence by sentence, on your Mac. ";
  const text = Array.from({ length: 3000 }, (_, index) => `${paragraph}${index % 7 === 0 ? "\n\n" : ""}`).join("");
  const chunks = splitIntoChunks(text);
  assert.ok(chunks.length >= 3);
  for (const chunk of chunks) {
    assert.ok(chunk.length > 0 && chunk.length <= MAX_SPEAK_CHARS);
  }
  const squash = (value) => value.replace(/\s+/g, "");
  assert.equal(squash(chunks.join("")), squash(text));
});

test("does not cut tiny chunks when a boundary is too early", () => {
  const text = `Hi. ${"x".repeat(30)} ${"y".repeat(30)}`;
  const chunks = splitIntoChunks(text, 40);
  assert.equal(chunks[0], `Hi. ${"x".repeat(30)}`);
});

test("rejects invalid limits", () => {
  assert.throws(() => splitIntoChunks("text", 1), RangeError);
  assert.throws(() => splitIntoChunks("text", 2.5), RangeError);
});
