import { DEFAULT_PORT, parseSettings } from "./config.js";
import { notConfiguredError } from "./errors.js";

const KEYS = ["port", "apiKey"];

export async function loadSettings(area) {
  const stored = await area.get(KEYS);
  return {
    port: Number.isInteger(stored?.port) ? stored.port : DEFAULT_PORT,
    apiKey: typeof stored?.apiKey === "string" ? stored.apiKey : "",
  };
}

export async function saveSettings(area, input) {
  const parsed = parseSettings(input);
  if (parsed.ok) {
    await area.set(parsed.value);
  }
  return parsed;
}

export async function requireSettings(area) {
  const parsed = parseSettings(await loadSettings(area));
  if (!parsed.ok) {
    throw notConfiguredError();
  }
  return parsed.value;
}
