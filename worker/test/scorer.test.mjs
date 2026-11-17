import assert from "node:assert/strict";
import test from "node:test";
import { createServer } from "../lib/http.mjs";
import { createScorer, EmbeddingCache, MAX_CANDIDATES } from "../lib/scorer.mjs";

// Fake pipeline: the "audio" for a URL is a single number taken from the URL,
// and the "embedding" is a 2-D direction derived from it.
function fakePipeline({ failing = [] } = {}) {
  const calls = { fetch: [], embed: 0, maxConcurrentEmbeds: 0 };
  let embedding = 0;
  return {
    calls,
    fetchClip: async (url) => {
      calls.fetch.push(url);
      if (failing.some((part) => url.includes(part))) throw new Error("Preview download failed with status 403");
      return Buffer.from(url);
    },
    decode: async (bytes) => Float32Array.of(Number(/angle=(-?\d+)/.exec(bytes.toString())[1])),
    embedWindow: async (samples) => {
      embedding += 1;
      calls.maxConcurrentEmbeds = Math.max(calls.maxConcurrentEmbeds, embedding);
      await new Promise((resolve) => setTimeout(resolve, 2));
      embedding -= 1;
      calls.embed += 1;
      const radians = (samples[0] * Math.PI) / 180;
      return Float32Array.of(Math.cos(radians), Math.sin(radians));
    },
  };
}

const track = (id, angle) => ({ id, preview: `https://cdnt-preview.dzcdn.net/${id}.mp3?angle=${angle}` });
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-5, `${actual} is not close to ${expected}`);

test("scores each candidate by the cosine of its embedding against the seed", async () => {
  const pipeline = fakePipeline();
  const score = createScorer(pipeline);

  const { scores, failed } = await score({ seed: track(1, 0), candidates: [track(2, 0), track(3, 60), track(4, 90), track(5, 180)] });

  close(scores["2"], 1);
  close(scores["3"], 0.5);
  close(scores["4"], 0);
  close(scores["5"], -1);
  assert.deepEqual(failed, []);
  assert.equal(pipeline.calls.maxConcurrentEmbeds, 1, "model inference runs one at a time");
});

test("a candidate that fails is reported and does not sink the rest", async () => {
  const pipeline = fakePipeline({ failing: ["/3.mp3"] });
  const score = createScorer(pipeline);

  const { scores, failed } = await score({ seed: track(1, 0), candidates: [track(2, 0), track(3, 60)] });

  assert.deepEqual(Object.keys(scores), ["2"]);
  assert.deepEqual(failed, [{ id: 3, error: "Preview download failed with status 403" }]);
});

test("a seed that fails rejects the whole request", async () => {
  const score = createScorer(fakePipeline({ failing: ["/1.mp3"] }));
  await assert.rejects(score({ seed: track(1, 0), candidates: [track(2, 0)] }), /status 403/);
});

test("embeddings are cached by track id, including across requests and duplicates", async () => {
  const pipeline = fakePipeline();
  const score = createScorer(pipeline);

  await score({ seed: track(1, 0), candidates: [track(2, 30), track(2, 30)] });
  await score({ seed: track(1, 0), candidates: [track(2, 30), track(3, 45)] });

  assert.equal(pipeline.calls.embed, 3, "tracks 1, 2 and 3 are each embedded once");
  assert.equal(pipeline.calls.fetch.length, 3);
});

test("input is validated before any work starts", async () => {
  const pipeline = fakePipeline();
  const score = createScorer(pipeline);

  await assert.rejects(score({ seed: { id: 1 }, candidates: [] }), /seed needs an id and a preview/);
  await assert.rejects(score({ seed: track(1, 0), candidates: "nope" }), /must be a list/);
  await assert.rejects(score({ seed: track(1, 0), candidates: [{ preview: "x" }] }), /candidate needs an id/);
  const tooMany = Array.from({ length: MAX_CANDIDATES + 1 }, (_, index) => track(index + 2, 0));
  await assert.rejects(score({ seed: track(1, 0), candidates: tooMany }), /At most 60/);
  assert.equal(pipeline.calls.fetch.length, 0);
});

test("EmbeddingCache evicts the least recently used entry", () => {
  const cache = new EmbeddingCache(2);
  cache.set("a", 1);
  cache.set("b", 2);
  cache.get("a");
  cache.set("c", 3);
  assert.equal(cache.get("b"), undefined);
  assert.equal(cache.get("a"), 1);
  assert.equal(cache.size, 2);
});

// ---- over HTTP -----------------------------------------------------------

async function withServer(options, run) {
  const server = createServer({ log: () => {}, ...options });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await run(base);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const post = (base, path, body) =>
  fetch(base + path, { method: "POST", headers: { "content-type": "application/json" }, body });

test("POST /scores answers in the shape the Ruby app reads", async () => {
  const score = createScorer(fakePipeline());
  await withServer({ score, info: { model: "test-model" } }, async (base) => {
    const response = await post(base, "/scores", JSON.stringify({ seed: track(1, 0), candidates: [track(2, 60)] }));
    assert.equal(response.status, 200);
    const body = await response.json();
    close(body.scores["2"], 0.5);
    assert.deepEqual(body.failed, []);

    const health = await (await fetch(`${base}/health`)).json();
    assert.deepEqual(health, { ok: true, model: "test-model" });
  });
});

test("bad requests get 400, analysis failures 502, unknown paths 404", async () => {
  const score = createScorer(fakePipeline({ failing: ["/1.mp3"] }));
  await withServer({ score }, async (base) => {
    const notJson = await post(base, "/scores", "{nope");
    assert.equal(notJson.status, 400);
    assert.deepEqual(await notJson.json(), { error: "Send a JSON object" });

    assert.equal((await post(base, "/scores", "[]")).status, 400);
    assert.equal((await post(base, "/scores", JSON.stringify({ seed: {}, candidates: [] }))).status, 400);

    const seedFailed = await post(base, "/scores", JSON.stringify({ seed: track(1, 0), candidates: [] }));
    assert.equal(seedFailed.status, 502);
    assert.match((await seedFailed.json()).error, /status 403/);

    assert.equal((await fetch(`${base}/nope`)).status, 404);
    assert.equal((await fetch(`${base}/scores`)).status, 404);
  });
});

test("oversized bodies are refused", async () => {
  await withServer({ score: async () => ({ scores: {}, failed: [] }) }, async (base) => {
    const big = JSON.stringify({ padding: "x".repeat(300 * 1024) });
    const outcome = await post(base, "/scores", big).then(
      (response) => response.status,
      () => "connection closed",
    );
    assert.ok(outcome === 400 || outcome === "connection closed", String(outcome));
  });
});
