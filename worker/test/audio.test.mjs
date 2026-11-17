import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { decode, fetchClip, isAllowedPreview } from "../lib/audio.mjs";

const hasFfmpeg = spawnSync("ffmpeg", ["-version"]).status === 0;

// A one-second 440 Hz tone, encoded as MP3 by ffmpeg itself.
function toneMp3() {
  const result = spawnSync(
    "ffmpeg",
    ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-ac", "2", "-f", "mp3", "pipe:1"],
    { maxBuffer: 16 * 1024 * 1024 },
  );
  assert.equal(result.status, 0, String(result.stderr));
  return result.stdout;
}

test("only Deezer's preview CDN over https is allowed", () => {
  assert.equal(isAllowedPreview("https://cdnt-preview.dzcdn.net/api/1/1/a/b/c.mp3?hdnea=exp=1"), true);
  assert.equal(isAllowedPreview("https://cdns-preview-5.dzcdn.net/stream/c-abc.mp3"), true);
  assert.equal(isAllowedPreview("http://cdnt-preview.dzcdn.net/x.mp3"), false);
  assert.equal(isAllowedPreview("https://dzcdn.net.evil.example/x.mp3"), false);
  assert.equal(isAllowedPreview("https://evil.example/?u=.dzcdn.net"), false);
  assert.equal(isAllowedPreview("https://user@cdnt-preview.dzcdn.net/x.mp3"), false);
  assert.equal(isAllowedPreview("https://cdnt-preview.dzcdn.net:8443/x.mp3"), false);
  assert.equal(isAllowedPreview("https://127.0.0.1/x.mp3"), false);
  assert.equal(isAllowedPreview("file:///etc/passwd"), false);
  assert.equal(isAllowedPreview("not a url"), false);
  assert.equal(isAllowedPreview(undefined), false);
});

test("fetchClip refuses other hosts without making a request", async () => {
  let called = false;
  const fetchImpl = async () => {
    called = true;
  };
  await assert.rejects(fetchClip("https://example.com/a.mp3", { fetchImpl }), /not on Deezer/);
  assert.equal(called, false);
});

test("fetchClip returns the bytes and refuses redirects, errors and empty bodies", async () => {
  const url = "https://cdnt-preview.dzcdn.net/a.mp3";
  let options;
  const ok = async (_url, init) => {
    options = init;
    return { ok: true, status: 200, arrayBuffer: async () => Uint8Array.of(1, 2, 3).buffer };
  };
  assert.deepEqual([...(await fetchClip(url, { fetchImpl: ok }))], [1, 2, 3]);
  assert.equal(options.redirect, "error");

  const gone = async () => ({ ok: false, status: 403, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(fetchClip(url, { fetchImpl: gone }), /status 403/);

  const empty = async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(fetchClip(url, { fetchImpl: empty }), /empty/);
});

test("decode turns an MP3 into mono float samples at the requested rate", { skip: !hasFfmpeg && "ffmpeg not installed" }, async () => {
  const samples = await decode(toneMp3(), { sampleRate: 48000 });

  assert.ok(samples instanceof Float32Array);
  // One second of audio; MP3 adds a little padding at the edges.
  assert.ok(samples.length > 47000 && samples.length < 52000, `got ${samples.length} samples`);
  const peak = samples.reduce((max, value) => Math.max(max, Math.abs(value)), 0);
  assert.ok(peak > 0.05 && peak <= 1.0, `peak ${peak}`);

  // A 440 Hz tone crosses zero 880 times a second, so about 440 times in the
  // middle half second (the edges hold MP3 padding, which is near-silent noise).
  const middle = samples.subarray(12000, 36000);
  let crossings = 0;
  for (let i = 1; i < middle.length; i += 1) if (middle[i - 1] < 0 !== middle[i] < 0) crossings += 1;
  assert.ok(crossings >= 436 && crossings <= 444, `${crossings} zero crossings`);
});

test("decode reports unreadable audio", { skip: !hasFfmpeg && "ffmpeg not installed" }, async () => {
  await assert.rejects(decode(Buffer.from("this is not audio")), /could not decode|no audio/);
});

test("decode explains a missing ffmpeg", async () => {
  await assert.rejects(decode(Buffer.from("x"), { ffmpegPath: "/nonexistent/ffmpeg" }), /ffmpeg was not found/);
});
