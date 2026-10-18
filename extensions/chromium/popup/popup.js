import { ariaKeyShortcut } from "../src/shortcuts.js";
import { Action } from "../src/status.js";

const STATUS_KEY = "lastStatus";
const buttons = {
  readSelection: document.getElementById("read-selection"),
  readPage: document.getElementById("read-page"),
  readNext: document.getElementById("read-next"),
  stop: document.getElementById("stop"),
};
const statusLine = document.getElementById("status");

function render(status) {
  statusLine.textContent = status?.text ?? "";
  statusLine.dataset.kind = status?.kind ?? "idle";
  const progress = status?.progress;
  buttons.readNext.hidden = !progress;
  buttons.readNext.textContent = progress ? `Next Part (${progress.part + 1} of ${progress.total})` : "Next Part";
}

function setBusy(busy) {
  for (const button of Object.values(buttons)) {
    button.disabled = busy;
  }
}

async function activeTabId() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

async function send(type) {
  setBusy(true);
  try {
    const tabId = type === Action.readSelection || type === Action.readPage ? await activeTabId() : undefined;
    const status = await chrome.runtime.sendMessage({ type, tabId });
    render(status);
  } catch {
    render({ kind: "error", text: "Something went wrong. Try again." });
  } finally {
    setBusy(false);
  }
}

const commandButtons = new Map([
  ["read-selection", buttons.readSelection],
  ["stop-reading", buttons.stop],
]);

async function showShortcuts() {
  const commands = await chrome.commands.getAll();
  for (const command of commands) {
    const button = commandButtons.get(command.name);
    if (!button) {
      continue;
    }
    if (command.shortcut) {
      button.title = `${button.textContent} (${command.shortcut})`;
      button.setAttribute("aria-keyshortcuts", ariaKeyShortcut(command.shortcut));
    } else {
      button.removeAttribute("title");
      button.removeAttribute("aria-keyshortcuts");
    }
  }
}

async function start() {
  const stored = await chrome.storage.session.get(STATUS_KEY);
  const last = stored?.[STATUS_KEY];
  const status = await chrome.runtime.sendMessage({ type: Action.progress });
  render(last?.kind === "error" ? { ...last, progress: status?.progress ?? null } : status);
}

buttons.readSelection.addEventListener("click", () => send(Action.readSelection));
buttons.readPage.addEventListener("click", () => send(Action.readPage));
buttons.readNext.addEventListener("click", () => send(Action.readNextPart));
buttons.stop.addEventListener("click", () => send(Action.stop));
document.getElementById("open-options").addEventListener("click", () => chrome.runtime.openOptionsPage());
document.getElementById("open-shortcuts").addEventListener("click", () => {
  chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
});

showShortcuts().catch(() => undefined);
start().catch(() => render(null));
