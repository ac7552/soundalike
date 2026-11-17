import assert from "node:assert/strict";
import test from "node:test";
import { cosine, embedClip, mean, normalize, windows } from "../lib/vectors.mjs";

const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-6, `${actual} is not close to ${expected}`);

test("cosine of identical, opposite and unrelated vectors", () => {
  close(cosine([1, 2, 3], [2, 4, 6]), 1);
  close(cosine([1, 0], [-1, 0]), -1);
  close(cosine([1, 0], [0, 1]), 0);
  assert.equal(cosine([0, 0], [1, 1]), 0);
  assert.throws(() => cosine([1], [1, 2]), /sizes differ/);
});

test("normalize gives unit length and survives a zero vector", () => {
  const unit = normalize(Float32Array.of(3, 4));
  close(unit[0], 0.6);
  close(unit[1], 0.8);
  assert.deepEqual(Array.from(normalize(Float32Array.of(0, 0))), [0, 0]);
});

test("mean averages element by element", () => {
  assert.deepEqual(Array.from(mean([Float32Array.of(1, 3), Float32Array.of(3, 5)])), [2, 4]);
  assert.throws(() => mean([]), /zero vectors/);
});

test("windows cuts a clip and drops a short tail", () => {
  const clip = new Float32Array(25);
  assert.deepEqual(windows(clip, 10).map((piece) => piece.length), [10, 10, 5]);
  assert.deepEqual(windows(new Float32Array(24), 10).map((piece) => piece.length), [10, 10]);
  assert.deepEqual(windows(new Float32Array(7), 10).map((piece) => piece.length), [7]);
  assert.deepEqual(windows(new Float32Array(10), 10).map((piece) => piece.length), [10]);
  assert.throws(() => windows(clip, 0), /positive integer/);
});

test("embedClip averages the windows of a 30-second clip into one unit vector", async () => {
  const sampleRate = 100;
  const clip = new Float32Array(3000);
  clip.fill(1, 0, 1000);
  clip.fill(2, 1000, 2000);
  clip.fill(3, 2000, 3000);
  const seen = [];
  const embedWindow = async (piece) => {
    seen.push(piece.length);
    // Three orthogonal directions, one per window, with different lengths.
    return Float32Array.of(piece[0] === 1 ? 5 : 0, piece[0] === 2 ? 9 : 0, piece[0] === 3 ? 2 : 0);
  };

  const vector = await embedClip(clip, embedWindow, { sampleRate, windowSeconds: 10 });

  assert.deepEqual(seen, [1000, 1000, 1000]);
  // Each window is normalised first, so every window counts equally.
  const expected = 1 / Math.sqrt(3);
  vector.forEach((value) => close(value, expected));
});

test("embedClip refuses an empty clip", async () => {
  await assert.rejects(embedClip(new Float32Array(0), async () => Float32Array.of(1)), /no audio/);
});
