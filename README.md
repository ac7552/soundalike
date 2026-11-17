# Soundalike

Paste a song link, or let the page listen to what is playing, and get ten songs that sound like it.

Ruby on the server, plain JavaScript in the browser, and an optional Node worker that compares how the previews actually sound.

## Status

This is a first version. Read this table before relying on it.

| Part | State |
|---|---|
| Ruby server (link parsing, ranking, API, static files) | 106 tests pass, using stubbed API answers and a local test server |
| Browser page (search, playback, errors, microphone flow, mobile, dark mode) | Checked in headless Chrome against the real server code with stubbed API answers |
| Calls to the live services (Deezer, Last.fm, YouTube, Apple, SoundCloud, AudD) | **Not yet run.** Written from each service's documented format |
| Serving through Puma (`config.ru`) | **Not yet run.** The Rack app itself is tested by calling it directly |
| Worker: download, decode, scoring, HTTP | 21 tests pass, including a real ffmpeg decode |
| Worker: CLAP model inference | **Not yet run.** The model's feature extractor was run on test audio; the model download was not possible where this was built |

The first thing to do after cloning is the smoke test at the end of "Run it".

## Run it

You need Ruby 3.1 or newer.

```sh
bundle install
cp .env.example .env        # optional, see "Settings"
bundle exec puma -p 9292
```

Open <http://localhost:9292>.

Smoke test: paste a YouTube link to a song. You should see the song at the top and ten rows below it, each with a working preview. With no keys set, results come from Deezer's artist radio; add a Last.fm key for results matched to the exact song.

## Settings

All optional, read from the environment or from `.env`.

| Variable | What it switches on |
|---|---|
| `LASTFM_API_KEY` | Track-level similar songs from Last.fm listening data. Free key: <https://www.last.fm/api/account/create> |
| `AUDD_API_TOKEN` | The "Listen to what's playing" button. AudD is paid after a free allowance: <https://audd.io> |
| `RERANK_URL` | The audio worker, for example `http://127.0.0.1:4100` |
| `RERANK_WEIGHT` | How much the audio score counts against Last.fm's order, 0 to 1. Default 0.6 |

## How it works

1. **Identify the song.** The pasted link is never fetched. The server pulls an ID out of it and asks a fixed endpoint what it is: YouTube and SoundCloud oEmbed for the title, iTunes lookup for Apple Music links, Deezer for Deezer links. Typed text goes straight to Deezer search. Everything is then pinned to one Deezer track, which supplies the preview clip and artwork.
2. **Find candidates.** Last.fm's `track.getSimilar` returns neighbours ranked from listening data. If there is no key, or Last.fm has nothing for the song, Deezer's artist radio is used instead.
3. **Clean up.** Each candidate is matched to a Deezer track. Other versions of the seed (covers, sped-up edits, remasters), duplicates and tracks without a preview are dropped, and no artist gets more than two slots. Lookups stop as soon as enough candidates are found, and requests to Deezer are held under its limit of 50 per 5 seconds.
4. **Rerank by sound (optional).** The page shows the first ten immediately. If the worker is running, the page then asks for the same list reranked: the worker embeds each 30-second preview with CLAP, scores it against the seed, and the server blends that score with Last.fm's.

Listening works the same way after one extra step: the browser records eight seconds from the microphone, the server sends it to AudD, and the recognised song becomes the seed.

Supported links: YouTube (including YouTube Music and Shorts), Apple Music songs, Deezer tracks, SoundCloud tracks. Spotify links are refused with a message asking for another link or the artist and title.

## The audio worker

Needs Node 20 or newer and `ffmpeg` on the path.

```sh
cd worker
npm install
npm start                   # http://127.0.0.1:4100
```

Then set `RERANK_URL=http://127.0.0.1:4100` for the Ruby app and restart it.

The first request downloads the CLAP model (`Xenova/larger_clap_music_and_speech`, a few hundred MB) from Hugging Face and caches it; that request is slow. After that, embeddings are cached in memory by track, so repeat searches are fast. The worker only downloads from Deezer's preview CDN and listens on localhost only.

Each preview is cut into 10-second windows, embedded window by window, and averaged. CLAP reads 10 seconds at a time and would otherwise pick a random crop of a longer clip, which makes scores change from run to run.

## API

| Request | Body | Answer |
|---|---|---|
| `GET /api/config` | | `{ "listen": bool, "rerank": bool }` |
| `POST /api/similar` | `{ "input": "<link or artist - title>", "rerank": false }` | seed, results, source |
| `POST /api/recognize` | the raw recorded audio, with its `Content-Type` | same as `/api/similar` |

A result looks like this:

```json
{
  "seed": { "id": 1, "title": "…", "artist": "…", "cover": "…", "preview": "…", "link": "…" },
  "results": [
    { "rank": 1, "id": 2, "title": "…", "artist": "…", "preview": "…", "link": "…",
      "match": 0.83, "audio": 0.71, "score": 0.76 }
  ],
  "source": "lastfm",
  "reranked": true,
  "rerank_available": true,
  "notes": []
}
```

`match` is Last.fm's similarity, `audio` is the worker's cosine similarity (null until reranked), and `score` is what the list is sorted by. Errors come back as `{ "error": "…" }` with a 4xx or 5xx status.

## Layout

```
config.ru                 starts the Rack app
lib/soundalike/
  app.rb                  the web layer: three endpoints and static files
  link_resolver.rb        pasted link or text -> one Deezer track
  title_cleaner.rb        "Artist - Title (Official Video)" -> artist and title
  recommender.rb          candidates, filtering, blending
  deezer.rb lastfm.rb audd.rb reranker.rb    one small client per service
  http.rb cache.rb rate_limiter.rb env.rb    plumbing
public/                   index.html, style.css, app.js
worker/                   the optional Node audio worker
test/                     Ruby tests
```

## Tests

```sh
bin/test                  # Ruby, needs nothing beyond Ruby and minitest
cd worker && npm test     # Node; the decode tests are skipped without ffmpeg
```

Neither suite touches the internet.

## Before putting this on the public internet

- **Terms of the services.** Results show Deezer previews and artwork and link back to Deezer and Last.fm, which those services ask for. Last.fm's API is non-commercial by default. Analysing preview clips with the worker is a grey area for a public service; read Deezer's terms first. This is not legal advice.
- **HTTPS.** Browsers only allow microphone access on `https://` or `localhost`.
- **Abuse limits.** Nothing limits how often a visitor can search. Every search costs upstream calls, and every recognition costs AudD money. Put a limiter in front of `/api/similar` and `/api/recognize`.
- **Cache and quota.** The cache and the Deezer request limiter are in memory, per process. Use Redis or a database once there is more than one process. Preview URLs expire, so cache them for minutes, not days.
- **Licence.** None has been chosen for this code yet.

## Where to take it next

1. Run the smoke test and fix whatever the live services do differently from their documentation.
2. Build a small test set of seeds with songs you agree are close, and tune `RERANK_WEIGHT` against it.
3. Store embeddings in a database so the index grows with every search.
4. Add a chord-progression and tempo score beside the CLAP score, and a producer filter from MusicBrainz credits.
