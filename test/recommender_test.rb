# frozen_string_literal: true

require_relative "test_helper"

class RecommenderTest < Minitest::Test
  SEED = Fixtures.track(id: 100, title: "we fell in love in october", artist: "girl in red", artist_id: 9)

  # Canned stand-ins for the clients; each records how it was used.
  class FakeLastfm
    attr_reader :calls

    def initialize(items, configured: true, error: nil)
      @items = items
      @configured = configured
      @error = error
      @calls = 0
    end

    def configured? = @configured

    def similar(artist:, title:, limit: 60)
      @calls += 1
      raise @error if @error

      @items
    end
  end

  class FakeDeezer
    attr_reader :searches, :radio_calls, :fallbacks

    def initialize(catalogue: {}, radio: [], failing: [])
      @catalogue = catalogue
      @radio = radio
      @failing = failing
      @searches = Queue.new
      @fallbacks = Queue.new
      @radio_calls = 0
    end

    def search(artist:, title:, fallback: true)
      @searches << title
      @fallbacks << fallback
      raise Soundalike::UpstreamError, "boom" if @failing.include?(title)

      @catalogue[title]
    end

    def artist_radio(_artist_id, limit: 40)
      @radio_calls += 1
      @radio
    end
  end

  class FakeReranker
    attr_reader :received

    def initialize(scores: {}, error: nil, configured: true)
      @scores = scores
      @error = error
      @configured = configured
    end

    def configured? = @configured

    def scores(seed, tracks)
      @received = [seed.id, tracks.map(&:id)]
      raise @error if @error

      @scores
    end
  end

  def similar_item(artist, title, match) = { artist: artist, title: title, match: match, url: nil }

  def build(lastfm_items:, catalogue:, **options)
    lastfm = options.delete(:lastfm) || FakeLastfm.new(lastfm_items)
    deezer = options.delete(:deezer) || FakeDeezer.new(catalogue: catalogue)
    [Soundalike::Recommender.new(deezer: deezer, lastfm: lastfm, **options), lastfm, deezer]
  end

  def test_keeps_lastfm_order_and_attaches_previews
    catalogue = {
      "Birch Tree" => Fixtures.track(id: 1, title: "Birch Tree", artist: "Strawberry Guy"),
      "Tired" => Fixtures.track(id: 2, title: "Tired", artist: "beabadoobee"),
      "If You Want To" => Fixtures.track(id: 3, title: "If You Want To", artist: "beabadoobee")
    }
    recommender, = build(
      lastfm_items: [similar_item("Strawberry Guy", "Birch Tree", 1.0), similar_item("beabadoobee", "Tired", 0.8),
                     similar_item("beabadoobee", "If You Want To", 0.6)],
      catalogue: catalogue
    )

    result = recommender.similar(SEED)

    assert_equal "lastfm", result[:source]
    assert_equal ["Birch Tree", "Tired", "If You Want To"], result[:results].map { |item| item[:title] }
    assert_equal [1, 2, 3], result[:results].map { |item| item[:rank] }
    assert_equal [1.0, 0.8, 0.6], result[:results].map { |item| item[:match] }
    assert_equal "https://cdnt-preview.dzcdn.net/1.mp3", result[:results].first[:preview]
    assert_equal "we fell in love in october", result[:seed][:title]
    refute result[:reranked]
    refute result[:rerank_available]
  end

  def test_drops_the_seed_its_other_versions_duplicates_and_tracks_without_preview
    catalogue = {
      "same id" => Fixtures.track(id: 100, title: "we fell in love in october", artist: "girl in red"),
      "sped up" => Fixtures.track(id: 2, title: "We Fell In Love In October - Sped Up", artist: "girl in red"),
      "cover" => Fixtures.track(id: 3, title: "we fell in love in october", artist: "Somebody Else"),
      "no preview" => Fixtures.track(id: 4, title: "Silent", artist: "x", preview: nil),
      "keep" => Fixtures.track(id: 5, title: "Juliet", artist: "Cavetown"),
      "dupe" => Fixtures.track(id: 6, title: "JULIET (Remastered)", artist: "cavetown"),
      "missing" => nil
    }
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, = build(lastfm_items: items, catalogue: catalogue)

    assert_equal [5], recommender.similar(SEED)[:results].map { |item| item[:id] }
  end

  def test_caps_tracks_per_artist
    catalogue = (1..4).to_h { |n| ["t#{n}", Fixtures.track(id: n, title: "Song #{n}", artist: "beabadoobee")] }
    catalogue["other"] = Fixtures.track(id: 9, title: "Other", artist: "Mitski")
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, = build(lastfm_items: items, catalogue: catalogue, per_artist: 2)

    assert_equal [1, 2, 9], recommender.similar(SEED)[:results].map { |item| item[:id] }
  end

  def test_limits_results_to_ten_by_default
    catalogue = (1..15).to_h { |n| ["t#{n}", Fixtures.track(id: n, title: "Song #{n}", artist: "Artist #{n}")] }
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, = build(lastfm_items: items, catalogue: catalogue)

    assert_equal 10, recommender.similar(SEED)[:results].size
    assert_equal 3, recommender.similar(SEED, limit: 3)[:results].size
  end

  def test_stops_looking_candidates_up_once_the_pool_is_full
    catalogue = (1..40).to_h { |n| ["t#{n}", Fixtures.track(id: n, title: "Song #{n}", artist: "Artist #{n}")] }
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, _, deezer = build(lastfm_items: items, catalogue: catalogue, threads: 3)

    result = recommender.similar(SEED)

    assert_equal 10, result[:results].size
    assert_equal (1..10).to_a, result[:results].map { |item| item[:id] }, "Last.fm's order is kept"
    # Default pool is 15 without the audio worker; batches are 6, so 18 lookups, not 40.
    assert_equal 18, deezer.searches.size
    assert_equal [false], Array.new(deezer.fallbacks.size) { deezer.fallbacks.pop }.uniq,
                 "bulk lookups never spend a second request"
  end

  def test_keeps_a_wider_pool_when_the_audio_worker_is_on
    catalogue = (1..40).to_h { |n| ["t#{n}", Fixtures.track(id: n, title: "Song #{n}", artist: "Artist #{n}")] }
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    reranker = FakeReranker.new(scores: (1..40).to_h { |n| [n.to_s, n / 40.0] })
    recommender, _, deezer = build(lastfm_items: items, catalogue: catalogue, reranker: reranker, threads: 3)

    recommender.similar(SEED, rerank: true)

    assert_equal 30, deezer.searches.size
    assert_equal 30, reranker.received.last.size
  end

  def test_keeps_looking_when_early_candidates_are_filtered_out
    catalogue = (1..12).to_h { |n| ["dupe#{n}", Fixtures.track(id: n, title: "Same Song", artist: "Same Artist")] }
    catalogue.merge!((13..30).to_h { |n| ["t#{n}", Fixtures.track(id: n, title: "Song #{n}", artist: "Artist #{n}")] })
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, = build(lastfm_items: items, catalogue: catalogue, threads: 3)

    assert_equal 10, recommender.similar(SEED)[:results].size
  end

  def test_gives_up_after_max_lookups
    catalogue = (1..60).to_h { |n| ["t#{n}", nil] }
    items = catalogue.keys.map { |title| similar_item("a", title, 0.5) }
    recommender, _, deezer = build(lastfm_items: items, catalogue: catalogue, max_lookups: 20)

    recommender.similar(SEED)
    assert_equal 20, deezer.searches.size
  end

  def test_one_failed_lookup_does_not_sink_the_search
    catalogue = { "ok" => Fixtures.track(id: 1, title: "Fine", artist: "x") }
    deezer = FakeDeezer.new(catalogue: catalogue, failing: ["bad"])
    recommender, = build(lastfm_items: [similar_item("a", "bad", 0.9), similar_item("a", "ok", 0.8)],
                         catalogue: catalogue, deezer: deezer)

    assert_equal [1], recommender.similar(SEED)[:results].map { |item| item[:id] }
  end

  def test_falls_back_to_artist_radio_without_a_lastfm_key
    radio = [Fixtures.track(id: 1, title: "Radio One", artist: "x"), Fixtures.track(id: 2, title: "Radio Two", artist: "y")]
    deezer = FakeDeezer.new(radio: radio)
    recommender, lastfm, = build(lastfm_items: [], catalogue: {}, deezer: deezer,
                                 lastfm: FakeLastfm.new([], configured: false))

    result = recommender.similar(SEED)

    assert_equal "deezer_radio", result[:source]
    assert_equal [1, 2], result[:results].map { |item| item[:id] }
    assert_operator result[:results][0][:match], :>, result[:results][1][:match]
    assert_equal 1, lastfm.calls
  end

  def test_falls_back_to_artist_radio_when_lastfm_knows_nothing
    deezer = FakeDeezer.new(radio: [Fixtures.track(id: 1, title: "Radio One", artist: "x")])
    recommender, = build(lastfm_items: [], catalogue: {}, deezer: deezer)
    assert_equal "deezer_radio", recommender.similar(SEED)[:source]
  end

  def test_no_candidates_at_all
    recommender, = build(lastfm_items: [], catalogue: {})
    result = recommender.similar(SEED)
    assert_nil result[:source]
    assert_empty result[:results]
  end

  def test_lastfm_key_errors_surface_instead_of_silently_falling_back
    lastfm = FakeLastfm.new([], error: Soundalike::UpstreamError.new("Last.fm rejected the API key."))
    recommender, = build(lastfm_items: [], catalogue: {}, lastfm: lastfm)
    assert_raises(Soundalike::UpstreamError) { recommender.similar(SEED) }
  end

  def test_pool_is_cached_between_calls_but_empty_pools_are_not
    catalogue = { "t" => Fixtures.track(id: 1, title: "Song", artist: "x") }
    recommender, lastfm, = build(lastfm_items: [similar_item("a", "t", 0.5)], catalogue: catalogue)
    2.times { recommender.similar(SEED) }
    assert_equal 1, lastfm.calls

    empty, empty_lastfm, = build(lastfm_items: [], catalogue: {})
    2.times { empty.similar(SEED) }
    assert_equal 2, empty_lastfm.calls
  end

  def rerank_setup(reranker, weight: 1.0)
    catalogue = {
      "a" => Fixtures.track(id: 1, title: "Alpha", artist: "one"),
      "b" => Fixtures.track(id: 2, title: "Beta", artist: "two"),
      "c" => Fixtures.track(id: 3, title: "Gamma", artist: "three")
    }
    items = [similar_item("x", "a", 1.0), similar_item("x", "b", 0.5), similar_item("x", "c", 0.0)]
    build(lastfm_items: items, catalogue: catalogue, reranker: reranker, rerank_weight: weight).first
  end

  def test_rerank_reorders_by_audio_when_weight_is_one
    reranker = FakeReranker.new(scores: { "1" => 0.2, "2" => 0.9, "3" => 0.5 })
    result = rerank_setup(reranker).similar(SEED, rerank: true)

    assert result[:reranked]
    assert result[:rerank_available]
    assert_equal [2, 3, 1], result[:results].map { |item| item[:id] }
    assert_equal [0.9, 0.5, 0.2], result[:results].map { |item| item[:audio] }
    assert_equal [1, 2, 3], result[:results].map { |item| item[:rank] }
    assert_equal [100, [1, 2, 3]], reranker.received
  end

  def test_rerank_blends_listening_data_and_audio
    # match scaled: 1.0, 0.5, 0.0. audio scaled: 0.0, 1.0, 0.5. Equal weight => 0.5, 0.75, 0.25.
    reranker = FakeReranker.new(scores: { "1" => 0.2, "2" => 0.8, "3" => 0.5 })
    result = rerank_setup(reranker, weight: 0.5).similar(SEED, rerank: true)

    assert_equal [2, 1, 3], result[:results].map { |item| item[:id] }
    assert_equal [0.75, 0.5, 0.25], result[:results].map { |item| item[:score] }
  end

  def test_rerank_gives_unscored_tracks_the_median_audio_score
    # Track 2 has no audio score: it takes the median of the scaled scores (0.5).
    reranker = FakeReranker.new(scores: { "1" => 0.2, "3" => 0.8 })
    result = rerank_setup(reranker, weight: 1.0).similar(SEED, rerank: true)

    assert_equal [3, 2, 1], result[:results].map { |item| item[:id] }
    assert_nil result[:results][1][:audio]
    assert_equal 0.5, result[:results][1][:score]
  end

  def test_rerank_failure_keeps_the_original_order_and_says_why
    reranker = FakeReranker.new(error: Soundalike::UpstreamError.new("The audio worker failed."))
    result = rerank_setup(reranker).similar(SEED, rerank: true)

    refute result[:reranked]
    assert_equal [1, 2, 3], result[:results].map { |item| item[:id] }
    assert_match(/Audio matching was skipped/, result[:notes].first)
  end

  def test_rerank_is_not_called_unless_asked_or_configured
    reranker = FakeReranker.new(scores: { "1" => 0.1 })
    rerank_setup(reranker).similar(SEED, rerank: false)
    assert_nil reranker.received

    off = FakeReranker.new(configured: false)
    result = rerank_setup(off).similar(SEED, rerank: true)
    assert_nil off.received
    refute result[:reranked]
  end

  def test_rerank_does_not_change_the_cached_pool
    reranker = FakeReranker.new(scores: { "1" => 0.2, "2" => 0.9, "3" => 0.5 })
    recommender = rerank_setup(reranker)
    recommender.similar(SEED, rerank: true)

    plain = recommender.similar(SEED, rerank: false)
    assert_equal [1, 2, 3], plain[:results].map { |item| item[:id] }
    assert_equal [nil, nil, nil], plain[:results].map { |item| item[:audio] }
  end
end
