// Small vector helpers shared by the worker. No dependencies.

export function norm(vector) {
  let sum = 0;
  for (let i = 0; i < vector.length; i += 1) sum += vector[i] * vector[i];
  return Math.sqrt(sum);
}

export function normalize(vector) {
  const length = norm(vector);
  const out = new Float32Array(vector.length);
  if (length === 0) return out;
  for (let i = 0; i < vector.length; i += 1) out[i] = vector[i] / length;
  return out;
}

export function cosine(a, b) {
  if (a.length !== b.length) throw new Error(`Vector sizes differ: ${a.length} and ${b.length}`);
  const lengths = norm(a) * norm(b);
  if (lengths === 0) return 0;
  let dot = 0;
  for (let i = 0; i < a.length; i += 1) dot += a[i] * b[i];
  return dot / lengths;
}

export function mean(vectors) {
  if (vectors.length === 0) throw new Error("Cannot average zero vectors");
  const out = new Float32Array(vectors[0].length);
  for (const vector of vectors) {
    if (vector.length !== out.length) throw new Error("Vector sizes differ");
    for (let i = 0; i < out.length; i += 1) out[i] += vector[i];
  }
  for (let i = 0; i < out.length; i += 1) out[i] /= vectors.length;
  return out;
}

// Cuts a clip into back-to-back windows. A short tail is dropped unless it is
// at least half a window, or the clip is shorter than one window altogether.
export function windows(samples, windowSize) {
  if (!Number.isInteger(windowSize) || windowSize <= 0) throw new Error("windowSize must be a positive integer");
  if (samples.length <= windowSize) return [samples];

  const out = [];
  for (let start = 0; start < samples.length; start += windowSize) {
    const piece = samples.subarray(start, start + windowSize);
    if (piece.length >= windowSize / 2) out.push(piece);
  }
  return out;
}

// Embeds a whole clip as the normalised average of its window embeddings.
// CLAP looks at 10 seconds at a time and would otherwise pick a random
// 10-second crop of a longer clip, which makes scores change between runs.
export async function embedClip(samples, embedWindow, { sampleRate = 48000, windowSeconds = 10 } = {}) {
  if (samples.length === 0) throw new Error("The clip has no audio");
  const pieces = windows(samples, Math.round(sampleRate * windowSeconds));
  const vectors = [];
  for (const piece of pieces) vectors.push(normalize(await embedWindow(piece)));
  return normalize(mean(vectors));
}
