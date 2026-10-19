export const DEFAULT_PORT = 51851;
export const MIN_PORT = 1024;
export const MAX_PORT = 65535;
export const MIN_KEY_LENGTH = 32;
export const MAX_KEY_LENGTH = 128;
export const MAX_SPEAK_CHARS = 50000;
export const MAX_PAGE_CHARS = 1000000;
export const REQUEST_TIMEOUT_MS = 10000;
export const SPEAK_MODE = Object.freeze({ replace: "replace", queue: "queue" });

const KEY_PATTERN = /^[A-Za-z0-9._~+/=-]+$/;

export function parsePort(value) {
  const text = String(value ?? "").trim();
  if (!/^\d{1,5}$/.test(text)) {
    return { ok: false, message: `Enter a port from ${MIN_PORT} to ${MAX_PORT}.` };
  }
  const port = Number(text);
  if (port < MIN_PORT || port > MAX_PORT) {
    return { ok: false, message: `Enter a port from ${MIN_PORT} to ${MAX_PORT}.` };
  }
  return { ok: true, value: port };
}

export function parseApiKey(value) {
  const key = String(value ?? "").trim();
  if (key.length === 0) {
    return { ok: false, message: "Paste the API key from Voqora -> Preferences -> Integrations." };
  }
  if (key.length < MIN_KEY_LENGTH || key.length > MAX_KEY_LENGTH || !KEY_PATTERN.test(key)) {
    return {
      ok: false,
      message: "That doesn't look like a Voqora API key. Copy it again from Preferences -> Integrations.",
    };
  }
  return { ok: true, value: key };
}

export function parseSettings(raw) {
  const port = parsePort(raw?.port);
  if (!port.ok) {
    return { ok: false, field: "port", message: port.message };
  }
  const apiKey = parseApiKey(raw?.apiKey);
  if (!apiKey.ok) {
    return { ok: false, field: "apiKey", message: apiKey.message };
  }
  return { ok: true, value: { port: port.value, apiKey: apiKey.value } };
}

export function endpointUrl(port, path) {
  const checked = parsePort(port);
  if (!checked.ok) {
    throw new RangeError(checked.message);
  }
  if (typeof path !== "string" || !path.startsWith("/v1/")) {
    throw new TypeError("Local API paths start with /v1/.");
  }
  return `http://127.0.0.1:${checked.value}${path}`;
}
