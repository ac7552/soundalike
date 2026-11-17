// Soundalike front end. No framework: one form, one shared <audio>, one list.
(() => {
  "use strict";

  const LISTEN_SECONDS = 8;

  const form = document.getElementById("ask");
  const input = document.getElementById("song");
  const findButton = document.getElementById("find");
  const listenButton = document.getElementById("listen");
  const statusLine = document.getElementById("status");
  const problem = document.getElementById("problem");
  const results = document.getElementById("results");
  const seedSlot = document.getElementById("seed");
  const trackList = document.getElementById("tracks");
  const note = document.getElementById("note");
  const player = document.getElementById("player");

  let features = { listen: false, rerank: false };
  let playingRow = null;
  let requestId = 0;

  // ---- helpers ---------------------------------------------------------

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // Everything shown comes from third-party APIs, so only https URLs are
  // ever used as link, image or audio sources.
  const safeUrl = (value) => (typeof value === "string" && value.startsWith("https://") ? value : null);

  const setBusy = (busy) => {
    findButton.disabled = busy;
    listenButton.disabled = busy;
    form.setAttribute("aria-busy", busy ? "true" : "false");
  };

  const say = (text) => {
    statusLine.textContent = text || "";
  };

  const showProblem = (text) => {
    problem.textContent = text;
    problem.hidden = false;
  };

  const clearProblem = () => {
    problem.hidden = true;
    problem.textContent = "";
  };

  async function api(path, options) {
    let response;
    try {
      response = await fetch(path, options);
    } catch (error) {
      throw new Error("Could not reach the server. Check your connection and try again.");
    }
    let body = null;
    try {
      body = await response.json();
    } catch (error) {
      // fall through with a null body
    }
    if (!response.ok) {
      throw new Error((body && body.error) || `The server answered with an error (${response.status}).`);
    }
    return body;
  }

  // ---- playback --------------------------------------------------------

  function stopPlayback() {
    player.pause();
    if (playingRow) {
      playingRow.classList.remove("is-playing");
      playingRow.style.setProperty("--progress", "0");
      const button = playingRow.querySelector(".play");
      button.setAttribute("aria-pressed", "false");
      playingRow = null;
    }
  }

  function toggle(row, previewUrl) {
    if (playingRow === row) {
      stopPlayback();
      return;
    }
    stopPlayback();
    playingRow = row;
    row.classList.add("is-playing");
    row.querySelector(".play").setAttribute("aria-pressed", "true");
    player.src = previewUrl;
    player.play().catch(() => {
      stopPlayback();
      showProblem("That preview could not be played. It may have expired: search again to refresh it.");
    });
  }

  player.addEventListener("timeupdate", () => {
    if (!playingRow || !player.duration) return;
    playingRow.style.setProperty("--progress", String(Math.min(player.currentTime / player.duration, 1)));
  });
  player.addEventListener("ended", stopPlayback);
  player.addEventListener("error", () => {
    if (!playingRow) return;
    stopPlayback();
    showProblem("That preview could not be played. It may have expired: search again to refresh it.");
  });

  // ---- rendering -------------------------------------------------------

  function trackRow(track, { rank } = {}) {
    const row = el(rank ? "li" : "div", "track");
    const title = track.title || "Untitled";
    const artist = track.artist || "Unknown artist";
    const link = safeUrl(track.link);
    const cover = safeUrl(track.cover);
    const preview = safeUrl(track.preview);

    if (rank) row.append(el("span", "track-rank", String(rank)));

    const image = el("img", "track-cover");
    image.alt = "";
    image.width = 56;
    image.height = 56;
    image.loading = "lazy";
    image.referrerPolicy = "no-referrer";
    // A cover that fails to load leaves a plain tile rather than a broken-image icon.
    image.addEventListener("error", () => image.removeAttribute("src"));
    if (cover) image.src = cover;
    row.append(image);

    const text = el("div", "track-text");
    const titleLine = el("p", "track-title");
    if (link) {
      const anchor = el("a", null, title);
      anchor.href = link;
      anchor.rel = "noopener";
      titleLine.append(anchor);
    } else {
      titleLine.textContent = title;
    }
    text.append(titleLine, el("p", "track-artist", artist));
    row.append(text);

    const actions = el("div", "track-actions");
    if (link) {
      const open = el("a", "track-link", "Open in Deezer");
      open.href = link;
      open.rel = "noopener";
      open.setAttribute("aria-label", `Open ${title} by ${artist} in Deezer`);
      actions.append(open);
    }
    if (preview) {
      const play = el("button", "play");
      play.type = "button";
      play.setAttribute("aria-pressed", "false");
      play.setAttribute("aria-label", `Play a preview of ${title} by ${artist}`);
      play.addEventListener("click", () => toggle(row, preview));
      actions.append(play);
    }
    row.append(actions);
    return row;
  }

  function render(data) {
    stopPlayback();
    seedSlot.replaceChildren(trackRow(data.seed));
    trackList.replaceChildren(...data.results.map((track) => trackRow(track, { rank: track.rank })));

    const notes = [];
    if (data.results.length === 0) {
      notes.push("No similar songs found for this one. Try another song.");
    } else if (data.source === "deezer_radio") {
      notes.push("These are matched by artist, not by this exact song.");
    }
    if (data.reranked) notes.push("Order refined by how the previews sound.");
    (data.notes || []).forEach((line) => notes.push(line));

    note.textContent = notes.join(" ");
    note.hidden = notes.length === 0;
    results.hidden = false;
  }

  // ---- searching -------------------------------------------------------

  const postSimilar = (text, rerank) =>
    api("/api/similar", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ input: text, rerank }),
    });

  // Shows the quick answer first, then quietly reorders it once the audio
  // worker (if there is one) has listened to the previews.
  async function refine(text, id) {
    say("Refining the order by sound…");
    try {
      const refined = await postSimilar(text, true);
      if (id !== requestId) return;
      if (refined.reranked || (refined.notes || []).length > 0) render(refined);
    } catch (error) {
      // The first answer is already on screen; a failed refinement is not worth an alert.
    } finally {
      if (id === requestId) say("");
    }
  }

  async function findSimilar(text) {
    const id = ++requestId;
    clearProblem();
    setBusy(true);
    say("Finding similar songs…");
    try {
      const data = await postSimilar(text, false);
      if (id !== requestId) return;
      render(data);
      say("");
      setBusy(false);
      if (data.rerank_available && data.results.length > 1) await refine(text, id);
    } catch (error) {
      if (id !== requestId) return;
      say("");
      showProblem(error.message);
    } finally {
      if (id === requestId) setBusy(false);
    }
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) {
      showProblem("Paste a song link or type an artist and title first.");
      input.focus();
      return;
    }
    findSimilar(text);
  });

  // ---- listening -------------------------------------------------------

  function pickRecordingType() {
    const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"];
    return candidates.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || "";
  }

  function record(stream, seconds, onTick) {
    return new Promise((resolve, reject) => {
      const type = pickRecordingType();
      const recorder = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
      const chunks = [];
      let remaining = seconds;
      onTick(remaining);
      const timer = setInterval(() => {
        remaining -= 1;
        if (remaining > 0) onTick(remaining);
      }, 1000);

      recorder.addEventListener("dataavailable", (event) => {
        if (event.data.size > 0) chunks.push(event.data);
      });
      recorder.addEventListener("error", () => {
        clearInterval(timer);
        reject(new Error("Recording failed. Try again."));
      });
      recorder.addEventListener("stop", () => {
        clearInterval(timer);
        resolve(new Blob(chunks, { type: recorder.mimeType || type || "audio/webm" }));
      });

      recorder.start();
      setTimeout(() => recorder.state !== "inactive" && recorder.stop(), seconds * 1000);
    });
  }

  async function listen() {
    const id = ++requestId;
    clearProblem();
    stopPlayback();
    setBusy(true);
    listenButton.setAttribute("aria-pressed", "true");

    let stream;
    try {
      // Voice processing (echo cancelling, noise suppression) mangles music, so it is switched off.
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      });
    } catch (error) {
      setBusy(false);
      listenButton.setAttribute("aria-pressed", "false");
      showProblem("Microphone access was blocked. Allow it for this site in your browser, then try again.");
      return;
    }

    try {
      const clip = await record(stream, LISTEN_SECONDS, (left) => say(`Listening… ${left}`));
      stream.getTracks().forEach((track) => track.stop());
      say("Recognising the song…");
      const data = await api("/api/recognize", {
        method: "POST",
        headers: { "content-type": clip.type || "audio/webm" },
        body: clip,
      });
      if (id !== requestId) return;
      input.value = `${data.seed.artist} - ${data.seed.title}`;
      render(data);
      say("");
    } catch (error) {
      if (id !== requestId) return;
      say("");
      showProblem(error.message);
    } finally {
      stream.getTracks().forEach((track) => track.stop());
      listenButton.setAttribute("aria-pressed", "false");
      if (id === requestId) setBusy(false);
    }
  }

  listenButton.addEventListener("click", listen);

  // ---- start -----------------------------------------------------------

  api("/api/config")
    .then((config) => {
      features = config || features;
      const canRecord = Boolean(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder);
      listenButton.hidden = !(features.listen && canRecord);
    })
    .catch(() => {
      // Without the config the page still works for pasted links.
    });
})();
