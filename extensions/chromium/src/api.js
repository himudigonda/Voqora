import { MAX_SPEAK_CHARS, REQUEST_TIMEOUT_MS, endpointUrl } from "./config.js";
import { ErrorCode, VoqoraError, errorFromFetchFailure, errorFromResponse } from "./errors.js";

async function readJson(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

export function createVoqoraClient({ port, apiKey, fetchImpl = globalThis.fetch, timeoutMs = REQUEST_TIMEOUT_MS }) {
  async function request(method, path, body) {
    const headers = { Authorization: `Bearer ${apiKey}`, Accept: "application/json" };
    const init = { method, headers, cache: "no-store", credentials: "omit", signal: AbortSignal.timeout(timeoutMs) };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    const url = endpointUrl(port, path);
    let response;
    try {
      response = await fetchImpl(url, init);
    } catch (error) {
      throw errorFromFetchFailure(error, port);
    }
    const json = await readJson(response);
    if (!response.ok) {
      throw errorFromResponse(response.status, json, response.headers.get("Retry-After"));
    }
    return { status: response.status, json };
  }

  function queuedId(result) {
    if (result.status !== 202 || result.json?.status !== "queued" || typeof result.json?.id !== "string") {
      throw new VoqoraError(ErrorCode.unexpectedResponse, "Voqora sent an unexpected reply.");
    }
    return result.json.id;
  }

  return Object.freeze({
    async listModels() {
      const result = await request("GET", "/v1/models");
      const data = result.json?.data;
      if (result.json?.object !== "list" || !Array.isArray(data)) {
        throw new VoqoraError(
          ErrorCode.unexpectedResponse,
          "Something answered on that port, but it isn't Voqora's local API. Check the port.",
        );
      }
      return data.map((model) => model?.id).filter((id) => typeof id === "string");
    },

    async speak(text) {
      if (typeof text !== "string" || text.trim().length === 0) {
        throw new VoqoraError(ErrorCode.invalidRequest, "There's no text to read.");
      }
      if (text.length > MAX_SPEAK_CHARS) {
        throw new VoqoraError(ErrorCode.tooLarge, "That text is too long to send in one request.");
      }
      return queuedId(await request("POST", "/v1/voqora/speak", { text }));
    },

    async stop() {
      return queuedId(await request("POST", "/v1/voqora/stop"));
    },
  });
}
