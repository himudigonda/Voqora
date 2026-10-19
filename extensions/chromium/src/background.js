import { createVoqoraClient } from "./api.js";
import { MAX_PAGE_CHARS } from "./config.js";
import { restrictedPageError } from "./errors.js";
import { createReader } from "./reader.js";
import { Action, badgeText, errorStatus, runAction } from "./status.js";

const MENU_READ_SELECTION = "voqora-read-selection";
const MENU_READ_PAGE = "voqora-read-page";
const STATUS_KEY = "lastStatus";
const PAGE_SCRIPT = "src/page-text.js";
const DEFAULT_TITLE = "Voqora";

async function runInTab(tabId, func, args = []) {
  try {
    await chrome.scripting.executeScript({ target: { tabId }, files: [PAGE_SCRIPT] });
    const [injection] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
    return typeof injection?.result === "string" ? injection.result : "";
  } catch {
    throw restrictedPageError();
  }
}

const pageAccess = Object.freeze({
  selection: (tabId) => runInTab(tabId, () => globalThis.VoqoraPageText.selectedText(window)),
  pageText: (tabId) =>
    runInTab(
      tabId,
      (maxChars) =>
        globalThis.VoqoraPageText.extractReadableText(document, {
          isHidden: globalThis.VoqoraPageText.browserIsHidden(window),
          maxChars,
        }),
      [MAX_PAGE_CHARS],
    ),
});

const reader = createReader({
  settingsArea: chrome.storage.local,
  createClient: (settings) => createVoqoraClient(settings),
  pageAccess,
});

async function showStatus(status) {
  await chrome.storage.session.set({ [STATUS_KEY]: status });
  await chrome.action.setBadgeText({ text: badgeText(status.badge) });
  if (status.kind === "error") {
    await chrome.action.setBadgeBackgroundColor({ color: "#C6483C" });
  } else if (status.badge) {
    await chrome.action.setBadgeBackgroundColor({ color: "#6C6A65" });
  }
  await chrome.action.setTitle({ title: status.text ? `${DEFAULT_TITLE}: ${status.text}` : DEFAULT_TITLE });
}

async function perform(message) {
  let status;
  try {
    status = await runAction(reader, message);
  } catch (error) {
    status = errorStatus(error);
    console.warn("Voqora action failed", { action: message?.type, code: status.code });
  }
  try {
    await showStatus(status);
  } catch {
    console.warn("Voqora status update failed", { action: message?.type });
  }
  return status;
}

function createMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_READ_SELECTION,
      title: "Read selection with Voqora",
      contexts: ["selection"],
    });
    chrome.contextMenus.create({
      id: MENU_READ_PAGE,
      title: "Read this page with Voqora",
      contexts: ["page"],
    });
  });
}

chrome.runtime.onInstalled.addListener((details) => {
  createMenus();
  if (details.reason === "install") {
    chrome.runtime.openOptionsPage();
  }
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const tabId = tab?.id;
  if (info.menuItemId === MENU_READ_SELECTION) {
    perform({ type: Action.readSelection, tabId, selectionText: info.selectionText });
  } else if (info.menuItemId === MENU_READ_PAGE && Number.isInteger(tabId)) {
    perform({ type: Action.readPage, tabId });
  }
});

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === "read-selection") {
    perform({ type: Action.readSelection, tabId: tab?.id });
  } else if (command === "stop-reading") {
    perform({ type: Action.stop });
  }
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const fromExtensionPage = sender.id === chrome.runtime.id && sender.url?.startsWith(chrome.runtime.getURL(""));
  if (!fromExtensionPage || !Object.values(Action).includes(message?.type)) {
    return false;
  }
  perform(message).then(sendResponse);
  return true;
});
