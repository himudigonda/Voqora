import { createVoqoraClient } from "../src/api.js";
import { parseSettings } from "../src/config.js";
import { userMessage } from "../src/errors.js";
import { loadSettings, saveSettings } from "../src/settings.js";

const form = document.getElementById("settings");
const portInput = document.getElementById("port");
const keyInput = document.getElementById("api-key");
const toggleKey = document.getElementById("toggle-key");
const saveButton = document.getElementById("save");
const testButton = document.getElementById("test");
const statusLine = document.getElementById("status");
const fieldErrors = {
  port: { input: portInput, message: document.getElementById("port-error") },
  apiKey: { input: keyInput, message: document.getElementById("api-key-error") },
};

function showStatus(kind, text) {
  statusLine.dataset.kind = kind;
  statusLine.textContent = text;
}

function clearFieldErrors() {
  for (const field of Object.values(fieldErrors)) {
    field.input.removeAttribute("aria-invalid");
    field.message.textContent = "";
  }
}

function validatedInput() {
  clearFieldErrors();
  const parsed = parseSettings({ port: portInput.value, apiKey: keyInput.value });
  if (!parsed.ok) {
    const field = fieldErrors[parsed.field];
    field.input.setAttribute("aria-invalid", "true");
    field.message.textContent = parsed.message;
    field.input.focus();
    showStatus("idle", "");
  }
  return parsed;
}

function setBusy(busy) {
  saveButton.disabled = busy;
  testButton.disabled = busy;
}

async function save(event) {
  event.preventDefault();
  if (!validatedInput().ok) {
    return;
  }
  setBusy(true);
  try {
    const result = await saveSettings(chrome.storage.local, { port: portInput.value, apiKey: keyInput.value });
    showStatus(result.ok ? "success" : "error", result.ok ? "Saved." : result.message);
  } catch {
    showStatus("error", "Couldn't save the settings. Try again.");
  } finally {
    setBusy(false);
  }
}

async function testConnection() {
  const parsed = validatedInput();
  if (!parsed.ok) {
    return;
  }
  setBusy(true);
  showStatus("idle", "Testing...");
  try {
    await createVoqoraClient(parsed.value).listModels();
    await saveSettings(chrome.storage.local, parsed.value);
    showStatus("success", "Connected to Voqora. Settings saved.");
  } catch (error) {
    showStatus("error", userMessage(error));
  } finally {
    setBusy(false);
  }
}

function toggleKeyVisibility() {
  const reveal = keyInput.type === "password";
  keyInput.type = reveal ? "text" : "password";
  toggleKey.textContent = reveal ? "Hide" : "Show";
  toggleKey.setAttribute("aria-pressed", String(reveal));
  toggleKey.setAttribute("aria-label", reveal ? "Hide API key" : "Show API key");
}

async function start() {
  const settings = await loadSettings(chrome.storage.local);
  portInput.value = String(settings.port);
  keyInput.value = settings.apiKey;
}

form.addEventListener("submit", save);
testButton.addEventListener("click", testConnection);
toggleKey.addEventListener("click", toggleKeyVisibility);
toggleKey.setAttribute("aria-label", "Show API key");
start().catch(() => showStatus("error", "Couldn't load the saved settings."));
