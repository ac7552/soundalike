# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

# Soundalike: paste a song link (or let the app listen), get ten similar songs.
module Soundalike
  # Every error the API can show to a user carries the HTTP status to answer with.
  class Error < StandardError
    def status = 500
  end

  class BadInput < Error
    def status = 400
  end

  class NotFound < Error
    def status = 404
  end

  class TooLarge < Error
    def status = 413
  end

  class UnsupportedLink < Error
    def status = 422
  end

  class NotConfigured < Error
    def status = 501
  end

  class UpstreamError < Error
    def status = 502
  end

  Track = Struct.new(
    :id, :title, :artist, :artist_id, :album, :cover, :preview, :link, :duration,
    keyword_init: true
  )
end

require_relative "soundalike/env"
require_relative "soundalike/http"
require_relative "soundalike/cache"
require_relative "soundalike/rate_limiter"
require_relative "soundalike/title_cleaner"
require_relative "soundalike/deezer"
require_relative "soundalike/lastfm"
require_relative "soundalike/audd"
require_relative "soundalike/link_resolver"
require_relative "soundalike/reranker"
require_relative "soundalike/recommender"
require_relative "soundalike/app"

module Soundalike
  # Wires the real clients together from environment variables.
  def self.build_app(public_dir:, env: ENV, http: HTTP.new)
    deezer = Deezer.new(http: http)
    lastfm = Lastfm.new(http: http, api_key: env["LASTFM_API_KEY"])
    audd = Audd.new(http: http, api_token: env["AUDD_API_TOKEN"])
    reranker = Reranker.new(http: http, url: env["RERANK_URL"])
    weight = Float(env["RERANK_WEIGHT"] || 0.6, exception: false) || 0.6

    App.new(
      resolver: LinkResolver.new(http: http, deezer: deezer),
      recommender: Recommender.new(deezer: deezer, lastfm: lastfm, reranker: reranker,
                                   rerank_weight: weight),
      audd: audd,
      deezer: deezer,
      public_dir: public_dir
    )
  end
end
