import { MAX_PAGE_CHARS } from "./config.js";
import { splitIntoChunks } from "./chunking.js";
import { noPageTextError, noSelectionError } from "./errors.js";
import { requireSettings } from "./settings.js";

export const SESSION_KEY = "readingSession";

function cleaned(text) {
  return typeof text === "string" ? text.trim().slice(0, MAX_PAGE_CHARS).trim() : "";
}

function progress(session) {
  return { part: session.index + 1, total: session.parts.length };
}

function isValidSession(session) {
  return Boolean(session)
    && Array.isArray(session.parts)
    && session.parts.every((part) => typeof part === "string" && part.length > 0)
    && Number.isInteger(session.index)
    && session.index >= 0
    && session.index < session.parts.length;
}

export function createReader({ settingsArea, sessionArea, createClient, pageAccess }) {
  async function client() {
    return createClient(await requireSettings(settingsArea));
  }

  async function loadSession() {
    const stored = await sessionArea.get(SESSION_KEY);
    const session = stored?.[SESSION_KEY];
    return isValidSession(session) ? session : null;
  }

  async function saveSession(session) {
    if (session.index < session.parts.length - 1) {
      await sessionArea.set({ [SESSION_KEY]: session });
    } else {
      await sessionArea.remove(SESSION_KEY);
    }
  }

  async function speakPart(session) {
    const voqora = await client();
    await voqora.speak(session.parts[session.index]);
    await saveSession(session);
    return progress(session);
  }

  function readText(text) {
    return speakPart({ parts: splitIntoChunks(text), index: 0 });
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

    async readNextPart() {
      const session = await loadSession();
      if (!session || session.index >= session.parts.length - 1) {
        await sessionArea.remove(SESSION_KEY);
        return null;
      }
      return speakPart({ parts: session.parts, index: session.index + 1 });
    },

    async stop() {
      await sessionArea.remove(SESSION_KEY);
      const voqora = await client();
      await voqora.stop();
    },

    async currentProgress() {
      const session = await loadSession();
      return session ? progress(session) : null;
    },
  });
}
