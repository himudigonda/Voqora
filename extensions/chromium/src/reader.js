import { MAX_PAGE_CHARS, SPEAK_MODE } from "./config.js";
import { splitIntoChunks } from "./chunking.js";
import { noPageTextError, noSelectionError } from "./errors.js";
import { requireSettings } from "./settings.js";

function cleaned(text) {
  return typeof text === "string" ? text.trim().slice(0, MAX_PAGE_CHARS).trim() : "";
}

export function createReader({ settingsArea, createClient, pageAccess }) {
  async function client() {
    return createClient(await requireSettings(settingsArea));
  }

  async function readText(text) {
    const parts = splitIntoChunks(text);
    const voqora = await client();
    for (const [index, part] of parts.entries()) {
      await voqora.speak(part, index === 0 ? SPEAK_MODE.replace : SPEAK_MODE.queue);
    }
    return { total: parts.length };
  }

  return Object.freeze({
    async readSelection({ tabId, selectionText } = {}) {
      let text = cleaned(selectionText);
      if (text.length === 0 && Number.isInteger(tabId)) {
        text = cleaned(await pageAccess.selection(tabId));
      }
      if (text.length === 0) {
        throw noSelectionError();
      }
      return readText(text);
    },

    async readPage({ tabId }) {
      const text = cleaned(await pageAccess.pageText(tabId));
      if (text.length === 0) {
        throw noPageTextError();
      }
      return readText(text);
    },

    async stop() {
      const voqora = await client();
      await voqora.stop();
    },
  });
}
