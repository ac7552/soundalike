# frozen_string_literal: true

module Soundalike
  # Client for the optional Node worker (see worker/), which listens to the
  # 30-second previews and scores how close each candidate sounds to the seed.
  # Off unless RERANK_URL is set.
  class Reranker
    def initialize(http:, url:)
      @http = http
      @url = url.to_s.strip.chomp("/")
    end

    def configured? = !@url.empty?

    # Returns { track_id => cosine similarity }. Tracks the worker could not
    # analyse are simply missing from the hash.
    def scores(seed, tracks)
      payload = {
        seed: { id: seed.id, preview: seed.preview },
        candidates: tracks.map { |track| { id: track.id, preview: track.preview } }
      }
      response = @http.post_json("#{@url}/scores", payload, read_timeout: 180)
      body = response.json
      unless response.ok? && body.is_a?(Hash) && body["scores"].is_a?(Hash)
        detail = body.is_a?(Hash) ? body["error"] : nil
        raise UpstreamError, "The audio worker failed#{detail ? ": #{detail}" : " (status #{response.status})"}."
      end

      body["scores"].each_with_object({}) do |(id, value), result|
        number = Float(value, exception: false)
        result[id.to_s] = number if number
      end
    end
  end
end
