# frozen_string_literal: true

require_relative "test_helper"

class DeezerTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @deezer = Soundalike::Deezer.new(http: @http)
  end

  def test_builds_a_track
    @http.stub("https://api.deezer.com/track/7", json: Fixtures.deezer_track(id: 7, title: "Tired", artist: "beabadoobee", artist_id: 99))
    track = @deezer.track(7)

    assert_equal [7, "Tired", "beabadoobee", 99], [track.id, track.title, track.artist, track.artist_id]
    assert_equal "https://cdn-images.dzcdn.net/7.jpg", track.cover
    assert_equal "https://www.deezer.com/track/7", track.link
  end

  def test_empty_preview_becomes_nil
    @http.stub("https://api.deezer.com/track/7", json: Fixtures.deezer_track(id: 7, title: "t", artist: "a", preview: ""))
    assert_nil @deezer.track(7).preview
  end

  def test_structured_search_falls_back_to_free_text
    queries = []
    @http.stub("https://api.deezer.com/search", json: lambda { |params, _|
      queries << params[:q]
      queries.size == 1 ? { "data" => [] } : { "data" => [Fixtures.deezer_track(id: 1, title: "t", artist: "a")] }
    })

    assert_equal 1, @deezer.search(artist: 'The "A" Band', title: "t").id
    assert_equal ['artist:"The A Band" track:"t"', 'The "A" Band t'], queries
  end

  def test_bulk_lookups_spend_a_single_request
    @http.stub("https://api.deezer.com/search", json: { "data" => [] })
    assert_nil @deezer.search(artist: "a", title: "t", fallback: false)
    assert_equal 1, @http.calls.size
  end

  def test_every_request_waits_for_the_rate_limiter
    waits = 0
    limiter = Object.new
    limiter.define_singleton_method(:wait) { waits += 1 }
    deezer = Soundalike::Deezer.new(http: @http, limiter: limiter)
    @http.stub("https://api.deezer.com/", json: { "data" => [] })

    deezer.search(artist: "a", title: "t")
    deezer.artist_radio(5)

    assert_equal 3, waits, "two search requests and one radio request"
  end

  def test_search_without_artist_uses_free_text
    @http.stub("https://api.deezer.com/search", json: { "data" => [] })
    assert_nil @deezer.search(artist: nil, title: "Space Girl")
    assert_equal "Space Girl", @http.calls.first.params[:q]
  end

  def test_quota_error_is_reported
    @http.stub("https://api.deezer.com/search", json: { "error" => { "type" => "Exception", "message" => "Quota limit exceeded", "code" => 4 } })
    error = assert_raises(Soundalike::UpstreamError) { @deezer.search_text("x") }
    assert_match(/rate-limiting/, error.message)
  end

  def test_server_error_is_reported
    @http.stub("https://api.deezer.com/search", status: 503, json: nil)
    assert_raises(Soundalike::UpstreamError) { @deezer.search_text("x") }
  end

  def test_non_numeric_track_id_is_refused
    assert_raises(ArgumentError) { @deezer.track("12/../album") }
    assert_empty @http.calls
  end

  def test_artist_radio
    @http.stub("https://api.deezer.com/artist/5/radio", json: { "data" => [
                 Fixtures.deezer_track(id: 1, title: "a", artist: "x"), { "bogus" => true },
                 Fixtures.deezer_track(id: 2, title: "b", artist: "y")
               ] })
    assert_equal [1, 2], @deezer.artist_radio(5).map(&:id)
  end
end

class LastfmTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @lastfm = Soundalike::Lastfm.new(http: @http, api_key: "key")
  end

  def test_not_configured_returns_nothing_and_makes_no_request
    lastfm = Soundalike::Lastfm.new(http: @http, api_key: " ")
    refute lastfm.configured?
    assert_empty lastfm.similar(artist: "a", title: "t")
    assert_empty @http.calls
  end

  def test_parses_similar_tracks
    @http.stub(Soundalike::Lastfm::BASE, json: { "similartracks" => { "track" => [
                 { "name" => "Birch Tree", "match" => 1.0, "url" => "https://www.last.fm/x", "artist" => { "name" => "Strawberry Guy" } },
                 { "name" => "Tired", "match" => "0.71", "artist" => { "name" => "beabadoobee" } },
                 { "name" => "", "artist" => { "name" => "nobody" } }
               ] } })

    result = @lastfm.similar(artist: "girl in red", title: "we fell in love in october")

    assert_equal [["Strawberry Guy", "Birch Tree", 1.0], ["beabadoobee", "Tired", 0.71]],
                 result.map { |item| item.values_at(:artist, :title, :match) }
    params = @http.calls.first.params
    assert_equal ["track.getsimilar", "girl in red", "we fell in love in october", "key", "json"],
                 params.values_at(:method, :artist, :track, :api_key, :format)
  end

  def test_single_track_object_is_accepted
    @http.stub(Soundalike::Lastfm::BASE, json: { "similartracks" => { "track" => { "name" => "t", "match" => 0.5, "artist" => { "name" => "a" } } } })
    assert_equal 1, @lastfm.similar(artist: "a", title: "b").size
  end

  def test_track_not_found_is_an_empty_list
    @http.stub(Soundalike::Lastfm::BASE, status: 404, json: { "error" => 6, "message" => "Track not found" })
    assert_empty @lastfm.similar(artist: "a", title: "b")
  end

  def test_invalid_key_is_reported
    @http.stub(Soundalike::Lastfm::BASE, status: 403, json: { "error" => 10, "message" => "Invalid API key" })
    error = assert_raises(Soundalike::UpstreamError) { @lastfm.similar(artist: "a", title: "b") }
    assert_match(/LASTFM_API_KEY/, error.message)
  end

  def test_unparseable_answer_is_reported
    @http.stub(Soundalike::Lastfm::BASE, status: 500, json: nil)
    assert_raises(Soundalike::UpstreamError) { @lastfm.similar(artist: "a", title: "b") }
  end
end

class AuddTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @audd = Soundalike::Audd.new(http: @http, api_token: "token")
  end

  def test_not_configured
    audd = Soundalike::Audd.new(http: @http, api_token: nil)
    refute audd.configured?
    assert_raises(Soundalike::NotConfigured) { audd.recognize(StringIO.new("x"), content_type: "audio/webm") }
  end

  def test_recognises_a_clip
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => {
                 "artist" => "girl in red", "title" => "we fell in love in october", "deezer" => { "id" => 42 }
               } })

    heard = @audd.recognize(StringIO.new("bytes"), content_type: "audio/webm;codecs=opus")

    assert_equal({ artist: "girl in red", title: "we fell in love in october", deezer_id: 42 }, heard)
    parts = @http.calls.first.payload
    assert_equal ["api_token", "token"], parts[0]
    assert_equal ["return", "deezer"], parts[1]
    assert_equal({ filename: "clip.webm", content_type: "audio/webm" }, parts[2][2])
  end

  def test_safari_recordings_get_an_m4a_name
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => nil })
    @audd.recognize(StringIO.new("bytes"), content_type: "audio/mp4")
    assert_equal "clip.m4a", @http.calls.first.payload[2][2][:filename]
  end

  def test_no_match_is_nil
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => nil })
    assert_nil @audd.recognize(StringIO.new("bytes"), content_type: "audio/webm")
  end

  def test_api_error_is_reported
    @http.stub(Soundalike::Audd::URL, json: { "status" => "error", "error" => { "error_code" => 900, "error_message" => "wrong api_token" } })
    error = assert_raises(Soundalike::UpstreamError) { @audd.recognize(StringIO.new("b"), content_type: "audio/webm") }
    assert_match(/wrong api_token/, error.message)
  end
end

class RerankerTest < Minitest::Test
  def test_posts_previews_and_reads_scores
    http = FakeHTTP.new
    http.stub("http://127.0.0.1:4100/scores", json: { "scores" => { "2" => 0.9, "3" => "0.4", "4" => "n/a" } })
    reranker = Soundalike::Reranker.new(http: http, url: "http://127.0.0.1:4100/")
    seed = Fixtures.track(id: 1, title: "s", artist: "a")

    scores = reranker.scores(seed, [Fixtures.track(id: 2, title: "t", artist: "b")])

    assert_equal({ "2" => 0.9, "3" => 0.4 }, scores)
    payload = http.calls.first.payload
    assert_equal({ id: 1, preview: seed.preview }, payload[:seed])
    assert_equal [{ id: 2, preview: "https://cdnt-preview.dzcdn.net/2.mp3" }], payload[:candidates]
  end

  def test_worker_failure_is_reported
    http = FakeHTTP.new
    http.stub("http://w/scores", status: 500, json: { "error" => "ffmpeg missing" })
    reranker = Soundalike::Reranker.new(http: http, url: "http://w")
    error = assert_raises(Soundalike::UpstreamError) { reranker.scores(Fixtures.track(id: 1, title: "s", artist: "a"), []) }
    assert_match(/ffmpeg missing/, error.message)
  end

  def test_unconfigured
    refute Soundalike::Reranker.new(http: FakeHTTP.new, url: nil).configured?
  end
end

class RateLimiterTest < Minitest::Test
  def test_lets_a_burst_through_then_spaces_calls_to_the_window
    now = 0.0
    slept = []
    limiter = Soundalike::RateLimiter.new(limit: 3, per: 5, clock: -> { now },
                                          sleeper: lambda { |seconds|
                                            slept << seconds
                                            now += seconds
                                          })

    3.times { limiter.wait }
    assert_empty slept, "the first three calls fit in the window"

    now = 2.0
    limiter.wait
    assert_equal [3.0], slept, "the fourth waits until the first call is five seconds old"
    assert_equal 5.0, now

    limiter.wait
    assert_equal [3.0], slept, "by then the other early calls have left the window too"
  end

  def test_is_safe_across_threads
    limiter = Soundalike::RateLimiter.new(limit: 1000, per: 5)
    Array.new(8) { Thread.new { 50.times { limiter.wait } } }.each(&:join)
    assert_equal 400, limiter.instance_variable_get(:@stamps).size
  end
end

class CacheTest < Minitest::Test
  def test_expires_and_evicts
    now = 0.0
    cache = Soundalike::Cache.new(ttl: 10, max_entries: 2, clock: -> { now })

    assert_equal 1, cache.fetch(:a) { 1 }
    assert_equal 1, cache.fetch(:a) { flunk("should be cached") }
    now = 11.0
    assert_equal 2, cache.fetch(:a) { 2 }

    cache.write(:b, 1)
    cache.write(:c, 1)
    assert_equal 2, cache.size
    assert_nil cache.read(:a), "oldest entry is evicted first"
  end

  def test_nil_is_not_cached
    cache = Soundalike::Cache.new
    calls = 0
    2.times { cache.fetch(:k) { calls += 1; nil } }
    assert_equal 2, calls
  end
end

class EnvTest < Minitest::Test
  def test_loads_without_overriding
    require "tempfile"
    Tempfile.create("env") do |file|
      file.write("# comment\nLASTFM_API_KEY=abc # trailing\nexport AUDD_API_TOKEN=\"quoted # value\"\nEXISTING=new\n\nnot a line\n")
      file.flush
      env = { "EXISTING" => "old" }

      loaded = Soundalike::Env.load(file.path, env: env)

      assert_equal %w[LASTFM_API_KEY AUDD_API_TOKEN], loaded
      assert_equal({ "EXISTING" => "old", "LASTFM_API_KEY" => "abc", "AUDD_API_TOKEN" => "quoted # value" }, env)
    end
  end

  def test_missing_file
    assert_empty Soundalike::Env.load("/nonexistent/.env", env: {})
  end
end
