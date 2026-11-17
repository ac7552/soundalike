// Soundalike audio worker.
//
//   npm install && npm start
//
// Listens on 127.0.0.1 only: it is a private helper for the Ruby app, not a
// public service. Point the app at it with RERANK_URL=http://127.0.0.1:4100
import { decode, fetchClip } from "./lib/audio.mjs";
import { createClapEmbedder, SAMPLE_RATE } from "./lib/embedder.mjs";
import { createServer } from "./lib/http.mjs";
import { createScorer } from "./lib/scorer.mjs";

const port = Number(process.env.PORT || 4100);
const host = process.env.HOST || "127.0.0.1";

const embedder = createClapEmbedder();
const score = createScorer({ fetchClip, decode, embedWindow: embedder.embedWindow, sampleRate: SAMPLE_RATE });
const server = createServer({ score, info: { model: embedder.model } });

server.listen(port, host, () => {
  console.error(`soundalike worker on http://${host}:${port} (model: ${embedder.model})`);
  console.error("The model downloads on the first request; that one will be slow.");
});
