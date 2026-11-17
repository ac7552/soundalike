# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "stringio"
require "soundalike"

# Stands in for Soundalike::HTTP. No test touches the network.
class FakeHTTP
  Call = Struct.new(:verb, :url, :params, :payload)

  attr_reader :calls

  def initialize
    @stubs = []
    @calls = []
  end

  # matcher: a String the URL must start with, or a Proc given (url, params).
  def stub(matcher, status: 200, json: nil, raises: nil)
    @stubs << [matcher, status, json, raises]
    self
  end

  def get(url, params = {})
    respond(:get, url, params, nil)
  end

  def post_json(url, payload, read_timeout: nil)
    respond(:post_json, url, {}, payload)
  end

  def post_multipart(url, parts, read_timeout: nil)
    respond(:post_multipart, url, {}, parts)
  end

  private

  def respond(verb, url, params, payload)
    @calls << Call.new(verb, url, params, payload)
    _, status, json, raises = @stubs.find do |matcher, *|
      matcher.respond_to?(:call) ? matcher.call(url, params) : url.start_with?(matcher)
    end
    raise raises if raises
    raise "Unstubbed request: #{verb} #{url} #{params.inspect}" unless status

    Soundalike::HTTP::Response.new(status, json.respond_to?(:call) ? json.call(params, payload) : json)
  end
end

module Fixtures
  module_function

  def deezer_track(id:, title:, artist:, artist_id: 1, preview: "https://cdnt-preview.dzcdn.net/#{id}.mp3")
    {
      "id" => id, "title" => title, "duration" => 184,
      "link" => "https://www.deezer.com/track/#{id}", "preview" => preview,
      "artist" => { "id" => artist_id, "name" => artist },
      "album" => { "title" => "Album #{id}", "cover_medium" => "https://cdn-images.dzcdn.net/#{id}.jpg" }
    }
  end

  def track(id:, title:, artist:, artist_id: 1, preview: "https://cdnt-preview.dzcdn.net/#{id}.mp3")
    Soundalike::Track.new(
      id: id, title: title, artist: artist, artist_id: artist_id, album: "Album #{id}",
      cover: "https://cdn-images.dzcdn.net/#{id}.jpg", preview: preview,
      link: "https://www.deezer.com/track/#{id}", duration: 184
    )
  end
end
