// The worker's HTTP surface: POST /scores and GET /health, JSON both ways.
import http from "node:http";
import { InputError } from "./scorer.mjs";

const MAX_BODY_BYTES = 256 * 1024;

function send(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new InputError("Request body is too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
        resolve(parsed);
      } catch {
        reject(new InputError("Send a JSON object"));
      }
    });
    request.on("error", reject);
  });
}

export function createServer({ score, info = {}, log = console.error }) {
  return http.createServer(async (request, response) => {
    const path = (request.url || "").split("?")[0];
    try {
      if (request.method === "GET" && path === "/health") {
        send(response, 200, { ok: true, ...info });
      } else if (request.method === "POST" && path === "/scores") {
        send(response, 200, await score(await readJson(request)));
      } else {
        send(response, 404, { error: "No such endpoint" });
      }
    } catch (error) {
      if (error instanceof InputError) {
        send(response, 400, { error: error.message });
      } else {
        log(error);
        send(response, 502, { error: error.message || "Audio analysis failed" });
      }
    }
  });
}
