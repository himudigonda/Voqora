import { MAX_SPEAK_CHARS } from "./config.js";

const BOUNDARIES = [/\n\s*\n/g, /\n/g, /[.!?\u2026]["'\u201d\u2019)\]]*\s/g, /[;:,]\s/g, /\s/g];

function lastBoundaryEnd(window, minimumEnd) {
  for (const pattern of BOUNDARIES) {
    let best = -1;
    for (const match of window.matchAll(pattern)) {
      const end = match.index + match[0].length;
      if (end >= minimumEnd) {
        best = end;
      }
    }
    if (best > 0) {
      return best;
    }
  }
  return -1;
}

function safeHardCut(text, limit) {
  const code = text.charCodeAt(limit - 1);
  return code >= 0xd800 && code <= 0xdbff ? limit - 1 : limit;
}

export function splitIntoChunks(text, limit = MAX_SPEAK_CHARS) {
  if (!Number.isInteger(limit) || limit < 2) {
    throw new RangeError("Chunk limit must be an integer of at least 2.");
  }
  const chunks = [];
  let rest = String(text ?? "").trim();
  while (rest.length > limit) {
    const window = rest.slice(0, limit + 1);
    const boundary = lastBoundaryEnd(window, Math.floor(limit / 2));
    const cut = boundary > 0 ? Math.min(boundary, limit) : safeHardCut(rest, limit);
    const chunk = rest.slice(0, cut).trim();
    if (chunk.length > 0) {
      chunks.push(chunk);
    }
    rest = rest.slice(cut).trim();
  }
  if (rest.length > 0) {
    chunks.push(rest);
  }
  return chunks;
}
