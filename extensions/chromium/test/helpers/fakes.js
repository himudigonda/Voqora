import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

export function text(value) {
  return { nodeType: 3, nodeValue: value };
}

export function el(tag, attributes = {}, ...children) {
  const childNodes = children.flat().map((child) => (typeof child === "string" ? text(child) : child));
  return {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    childNodes,
    getAttribute: (name) => (Object.hasOwn(attributes, name) ? String(attributes[name]) : null),
    hasAttribute: (name) => Object.hasOwn(attributes, name),
  };
}

export function documentWith(...children) {
  return { body: el("body", {}, ...children) };
}

export function loadPageText() {
  const source = readFileSync(fileURLToPath(new URL("../../src/page-text.js", import.meta.url)), "utf8");
  const context = vm.createContext({});
  vm.runInContext(source, context);
  return context.VoqoraPageText;
}

export class MemoryArea {
  constructor(initial = {}) {
    this.data = { ...initial };
  }

  async get(keys) {
    const list = Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(list.filter((key) => Object.hasOwn(this.data, key)).map((key) => [key, this.data[key]]));
  }

  async set(items) {
    Object.assign(this.data, structuredClone(items));
  }

  async remove(keys) {
    for (const key of Array.isArray(keys) ? keys : [keys]) {
      delete this.data[key];
    }
  }
}

export function jsonResponse(status, body, headers = {}) {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

export function recordingFetch(responder) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return responder(url, init);
  };
  return { calls, fetchImpl };
}

export const VALID_KEY = "abcdefghijklmnopqrstuvwxyz012345-._~+/=";
