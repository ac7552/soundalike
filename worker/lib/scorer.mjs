// Turns a seed and a list of candidates into similarity scores.
import { cosine, embedClip } from "./vectors.mjs";

export const MAX_CANDIDATES = 60;

// A tiny least-recently-used cache keyed by track ID. Embeddings never change
// for a given recording, so they are safe to keep (unlike the preview URLs).
export class EmbeddingCache {
  constructor(limit = 5000) {
    this.limit = limit;
    this.map = new Map();
  }

  get(key) {
    if (!this.map.has(key)) return undefined;
    const value = this.map.get(key);
    this.map.delete(key);
    this.map.set(key, value);
    return value;
  }

  set(key, value) {
    this.map.delete(key);
    this.map.set(key, value);
    while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value);
  }

  get size() {
    return this.map.size;
  }
}

export function createScorer({ fetchClip, decode, embedWindow, cache = new EmbeddingCache(), sampleRate = 48000, downloads = 4 }) {
  // Model inference is serialised: running several at once only fights over the same CPU cores.
  let inferenceQueue = Promise.resolve();
  const inFlight = new Map();

  const embedTrack = (track) => {
    const key = String(track.id);
    const cached = cache.get(key);
    if (cached) return Promise.resolve(cached);
    if (inFlight.has(key)) return inFlight.get(key);

    const work = (async () => {
      const samples = await decode(await fetchClip(track.preview), { sampleRate });
      const run = inferenceQueue.then(() => embedClip(samples, embedWindow, { sampleRate }));
      inferenceQueue = run.catch(() => {});
      const vector = await run;
      cache.set(key, vector);
      return vector;
    })().finally(() => inFlight.delete(key));

    inFlight.set(key, work);
    return work;
  };

  // Returns { scores: { id: cosine }, failed: [{ id, error }] }.
  // Throws when the seed itself cannot be analysed.
  return async function score({ seed, candidates }) {
    validate(seed, "seed");
    if (!Array.isArray(candidates)) throw new InputError("candidates must be a list");
    if (candidates.length > MAX_CANDIDATES) throw new InputError(`At most ${MAX_CANDIDATES} candidates per request`);
    candidates.forEach((candidate) => validate(candidate, "candidate"));

    const seedVector = await embedTrack(seed);
    const scores = {};
    const failed = [];
    const queue = [...candidates];

    const drain = async () => {
      for (let track = queue.shift(); track; track = queue.shift()) {
        try {
          scores[String(track.id)] = cosine(seedVector, await embedTrack(track));
        } catch (error) {
          failed.push({ id: track.id, error: error.message });
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(downloads, queue.length) }, drain));

    return { scores, failed };
  };
}

export class InputError extends Error {}

function validate(track, label) {
  const idOk = track && (typeof track.id === "number" || typeof track.id === "string") && String(track.id).length > 0;
  if (!idOk || typeof track.preview !== "string") {
    throw new InputError(`Each ${label} needs an id and a preview URL`);
  }
}
