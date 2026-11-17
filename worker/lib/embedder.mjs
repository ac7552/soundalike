// CLAP audio embeddings through Transformers.js.
//
// The model (a few hundred MB) downloads from Hugging Face on first use and is
// cached on disk afterwards. Loading is lazy so the server starts instantly
// and the tests never need the model.

export const DEFAULT_MODEL = "Xenova/larger_clap_music_and_speech";
export const SAMPLE_RATE = 48000;

export function createClapEmbedder({ model = process.env.CLAP_MODEL || DEFAULT_MODEL } = {}) {
  let loading = null;

  const load = () => {
    loading ??= (async () => {
      const { AutoProcessor, ClapAudioModelWithProjection } = await import("@huggingface/transformers");
      const [processor, audioModel] = await Promise.all([
        AutoProcessor.from_pretrained(model),
        ClapAudioModelWithProjection.from_pretrained(model),
      ]);
      return { processor, audioModel };
    })().catch((error) => {
      loading = null; // let the next request retry the download
      throw error;
    });
    return loading;
  };

  // samples: mono Float32Array at SAMPLE_RATE, at most 10 seconds long.
  const embedWindow = async (samples) => {
    const { processor, audioModel } = await load();
    const inputs = await processor(samples);
    const { audio_embeds: embeds } = await audioModel(inputs);
    return Float32Array.from(embeds.data);
  };

  return { model, embedWindow, load };
}
