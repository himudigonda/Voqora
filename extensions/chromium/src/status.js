import { userMessage } from "./errors.js";

export const Action = Object.freeze({
  readSelection: "read-selection",
  readPage: "read-page",
  readNextPart: "read-next-part",
  stop: "stop",
  progress: "progress",
});

export function readingStatus(progress) {
  if (!progress || progress.total <= 1) {
    return { kind: "info", text: "Voqora is reading.", badge: "", progress: null };
  }
  const text = progress.part < progress.total
    ? `Reading part ${progress.part} of ${progress.total}. Choose Next Part when this part ends.`
    : `Reading the last part (${progress.part} of ${progress.total}).`;
  const badge = progress.part < progress.total ? `${progress.part}/${progress.total}` : "";
  return { kind: "info", text, badge, progress: progress.part < progress.total ? progress : null };
}

export function stoppedStatus() {
  return { kind: "info", text: "Stopped.", badge: "", progress: null };
}

export function idleStatus(progress) {
  if (progress && progress.part < progress.total) {
    return readingStatus(progress);
  }
  return { kind: "idle", text: "", badge: "", progress: null };
}

export function errorStatus(error) {
  return { kind: "error", text: userMessage(error), badge: "!", code: error?.code ?? "unknown", progress: null };
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
    case Action.readNextPart: {
      const progress = await reader.readNextPart();
      return progress ? readingStatus(progress) : idleStatus(null);
    }
    case Action.stop:
      await reader.stop();
      return stoppedStatus();
    case Action.progress:
      return idleStatus(await reader.currentProgress());
    default:
      throw new TypeError("Unknown action.");
  }
}
