// Fetching and decoding preview clips.
import { spawn } from "node:child_process";

const MAX_CLIP_BYTES = 4 * 1024 * 1024;

// The worker only ever downloads from Deezer's preview CDN. The Ruby app
// passes it URLs, and this check keeps a bad URL from turning the worker
// into a way to fetch arbitrary addresses.
export function isAllowedPreview(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.protocol === "https:" && url.hostname.endsWith(".dzcdn.net") && url.username === "" && url.port === "";
}

export async function fetchClip(url, { fetchImpl = fetch, timeoutMs = 15000 } = {}) {
  if (!isAllowedPreview(url)) throw new Error("Preview URL is not on Deezer's CDN");

  const response = await fetchImpl(url, { redirect: "error", signal: AbortSignal.timeout(timeoutMs) });
  if (!response.ok) throw new Error(`Preview download failed with status ${response.status}`);

  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length === 0) throw new Error("Preview download was empty");
  if (bytes.length > MAX_CLIP_BYTES) throw new Error("Preview download was larger than expected");
  return bytes;
}

// Decodes any audio ffmpeg understands into mono 32-bit float samples.
export function decode(bytes, { sampleRate = 48000, ffmpegPath = process.env.FFMPEG_PATH || "ffmpeg" } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      ffmpegPath,
      ["-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-f", "f32le", "-ac", "1", "-ar", String(sampleRate), "pipe:1"],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    const out = [];
    let errors = "";

    child.stdout.on("data", (chunk) => out.push(chunk));
    child.stderr.on("data", (chunk) => {
      errors += chunk;
    });
    child.on("error", (error) => {
      reject(
        error.code === "ENOENT"
          ? new Error("ffmpeg was not found. Install it or set FFMPEG_PATH.")
          : error,
      );
    });
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`ffmpeg could not decode the clip: ${errors.trim().split("\n").pop() || `exit code ${code}`}`));
        return;
      }
      const raw = Buffer.concat(out);
      const usable = raw.length - (raw.length % 4);
      if (usable === 0) {
        reject(new Error("ffmpeg produced no audio"));
        return;
      }
      // Copy into a fresh buffer: Buffer.concat may hand back a slice of a shared pool.
      const samples = new Float32Array(usable / 4);
      for (let i = 0; i < samples.length; i += 1) samples[i] = raw.readFloatLE(i * 4);
      resolve(samples);
    });

    // ffmpeg may exit before reading everything; that surfaces through "close".
    child.stdin.on("error", () => {});
    child.stdin.end(bytes);
  });
}
