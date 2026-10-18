export const ErrorCode = Object.freeze({
  notConfigured: "not_configured",
  unreachable: "unreachable",
  timeout: "timeout",
  unauthorized: "unauthorized",
  forbidden: "forbidden",
  rateLimited: "rate_limited",
  appNotListening: "app_not_listening",
  tooLarge: "too_large",
  invalidRequest: "invalid_request",
  unsupported: "unsupported",
  serverError: "server_error",
  unexpectedResponse: "unexpected_response",
  noSelection: "no_selection",
  noPageText: "no_page_text",
  restrictedPage: "restricted_page",
});

const INTEGRATIONS = "Preferences -> Integrations";

export class VoqoraError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "VoqoraError";
    this.code = code;
  }
}

export function notConfiguredError() {
  return new VoqoraError(
    ErrorCode.notConfigured,
    `Add your port and API key in the extension options. You'll find both in Voqora -> ${INTEGRATIONS}.`,
  );
}

export function noSelectionError() {
  return new VoqoraError(ErrorCode.noSelection, "Select some text on the page first.");
}

export function noPageTextError() {
  return new VoqoraError(ErrorCode.noPageText, "Voqora couldn't find readable text on this page.");
}

export function restrictedPageError() {
  return new VoqoraError(
    ErrorCode.restrictedPage,
    "Your browser doesn't let extensions read this page. Try a regular web page.",
  );
}

export function retryAfterSeconds(value) {
  const seconds = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(seconds) || seconds < 1) {
    return 1;
  }
  return Math.min(seconds, 3600);
}

function backendMessage(body) {
  const message = body?.error?.message;
  if (typeof message !== "string") {
    return null;
  }
  const trimmed = message.trim();
  return trimmed.length > 0 && trimmed.length <= 300 ? trimmed : null;
}

export function errorFromResponse(status, body, retryAfter) {
  switch (status) {
    case 401:
      return new VoqoraError(
        ErrorCode.unauthorized,
        `Voqora didn't accept the API key. Copy it again from ${INTEGRATIONS} and save it in the extension options.`,
      );
    case 403:
      return new VoqoraError(
        ErrorCode.forbidden,
        "Voqora refused the request from this browser. Update Voqora and the extension, then try again.",
      );
    case 404:
    case 405:
      return new VoqoraError(
        ErrorCode.unsupported,
        "This version of Voqora can't read from the browser. Update Voqora and try again.",
      );
    case 413:
      return new VoqoraError(ErrorCode.tooLarge, "That text is too long to send in one request.");
    case 429: {
      const seconds = retryAfterSeconds(retryAfter);
      const wait = seconds === 1 ? "a second" : `${seconds} seconds`;
      return new VoqoraError(ErrorCode.rateLimited, `Voqora is busy. Try again in ${wait}.`);
    }
    case 503:
      return new VoqoraError(
        ErrorCode.appNotListening,
        "Voqora's speech service is on, but the app isn't listening. Open Voqora and try again.",
      );
    default:
      break;
  }
  if (status === 400 || status === 422) {
    const detail = backendMessage(body);
    return new VoqoraError(
      ErrorCode.invalidRequest,
      detail ? `Voqora couldn't read that text: ${detail}` : "Voqora couldn't read that text.",
    );
  }
  if (status >= 500) {
    return new VoqoraError(ErrorCode.serverError, "Voqora ran into a problem. Try again in a moment.");
  }
  return new VoqoraError(ErrorCode.unexpectedResponse, `Voqora sent an unexpected reply (HTTP ${status}).`);
}

export function errorFromFetchFailure(error, port) {
  if (error instanceof VoqoraError) {
    return error;
  }
  if (error?.name === "TimeoutError" || error?.name === "AbortError") {
    return new VoqoraError(ErrorCode.timeout, "Voqora didn't answer in time. Make sure it's open and try again.");
  }
  return new VoqoraError(
    ErrorCode.unreachable,
    `Can't reach Voqora on port ${port}. Open Voqora, turn on Local API in ${INTEGRATIONS}, and check that the port matches.`,
  );
}

export function userMessage(error) {
  if (error instanceof VoqoraError) {
    return error.message;
  }
  return "Something went wrong. Try again.";
}
