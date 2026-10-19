import { userMessage } from "./errors.js";

export const Action = Object.freeze({
  readSelection: "read-selection",
  readPage: "read-page",
  stop: "stop",
});

export function readingStatus({ total }) {
  const text = total > 1 ? `Voqora is reading ${total} parts in order.` : "Voqora is reading.";
  return { kind: "info", text, badge: "" };
}

export function stoppedStatus() {
  return { kind: "info", text: "Stopped.", badge: "" };
}

export function errorStatus(error) {
  return { kind: "error", text: userMessage(error), badge: "!", code: error?.code ?? "unknown" };
}

export function badgeText(text) {
  return String(text ?? "").slice(0, 4);
}

export async function runAction(reader, message) {
  switch (message?.type) {
    case Action.readSelection:
      return readingStatus(await reader.readSelection({ tabId: message.tabId, selectionText: message.selectionText }));
    case Action.readPage:
      return readingStatus(await reader.readPage({ tabId: message.tabId }));
    case Action.stop:
      await reader.stop();
      return stoppedStatus();
    default:
      throw new TypeError("Unknown action.");
  }
}
