# frozen_string_literal: true

module Soundalike
  # Seed track in, ranked similar tracks out.
  #
  #   1. Candidates: Last.fm's similar tracks (listening data). Falls back to
  #      Deezer's artist radio when Last.fm has no key or no data.
  #   2. Each candidate is matched to a Deezer track for its preview and art.
  #   3. Other versions of the seed, duplicates and artist pile-ups are removed.
  #   4. Optionally the audio worker re-scores the pool by how it sounds.
  class Recommender
    SOURCES = { lastfm: "lastfm", deezer_radio: "deezer_radio" }.freeze

    # pool_size: how many filtered candidates to keep per seed. Ten are shown;
    # the audio worker needs a wider pool to have something to reorder.
    def initialize(deezer:, lastfm:, reranker: nil, cache: Cache.new(ttl: 600),
                   pool_size: nil, max_lookups: 45, per_artist: 2, threads: 6, rerank_weight: 0.6)
      @deezer = deezer
      @lastfm = lastfm
      @reranker = reranker
      @cache = cache
      @pool_size = pool_size || (reranker&.configured? ? 30 : 15)
      @max_lookups = max_lookups
      @per_artist = per_artist
      @threads = threads
      @rerank_weight = rerank_weight.clamp(0.0, 1.0)
    end

    def rerank_available? = !!@reranker&.configured?

    def similar(seed, limit: 10, rerank: false)
      pool = cached_pool(seed)
      items = pool[:items].map(&:dup)
      notes = []
      reranked = false

      if rerank && rerank_available? && seed.preview && !items.empty?
        begin
          items = apply_audio_scores(seed, items)
          reranked = true
        rescue UpstreamError => e
          notes << "Audio matching was skipped: #{e.message}"
        end
      end

      {
        seed: seed.to_h,
        results: items.first(limit).each_with_index.map { |item, index| item.merge(rank: index + 1) },
        source: pool[:source],
        reranked: reranked,
        rerank_available: rerank_available?,
        notes: notes
      }
    end

    private

    # The pool is cached so the follow-up "rerank" request does not repeat the
    # lookups. Empty pools are not cached: they are usually a passing upstream hiccup.
    def cached_pool(seed)
      key = "pool:#{seed.id}"
      cached = @cache.read(key)
      return cached if cached

      pool = build_pool(seed)
      @cache.write(key, pool) unless pool[:items].empty?
      pool
    end

    def build_pool(seed)
      source = :lastfm
      items = lastfm_pool(seed)
      if items.empty?
        source = :deezer_radio
        items = filter(seed, radio_candidates(seed)).first(@pool_size)
      end

      { source: items.empty? ? nil : SOURCES.fetch(source), items: items }
    end

    # Looks candidates up on Deezer a batch at a time, in Last.fm's order, and
    # stops as soon as the pool is full. Most searches need far fewer lookups
    # than Last.fm returns, which keeps them quick and inside Deezer's quota.
    def lastfm_pool(seed)
      similar = @lastfm.similar(artist: seed.artist, title: seed.title).first(@max_lookups)
      scored = []
      items = []

      similar.each_slice(@threads * 2) do |batch|
        tracks = parallel_map(batch) do |item|
          @deezer.search(artist: item[:artist], title: item[:title], fallback: false)
        end
        scored.concat(batch.zip(tracks).filter_map { |item, track| [track, item[:match]] if track })
        items = filter(seed, scored)
        break if items.size >= @pool_size
      end

      items.first(@pool_size)
    end

    def radio_candidates(seed)
      return [] unless seed.artist_id

      tracks = @deezer.artist_radio(seed.artist_id, limit: @max_lookups)
      # Radio results carry no score, so rank position stands in for one.
      tracks.each_with_index.map { |track, index| [track, 1.0 - (index.to_f / [tracks.size, 1].max)] }
    end

    def filter(seed, scored)
      seed_title = TitleCleaner.normalize(seed.title)
      seen = {}
      per_artist = Hash.new(0)

      scored.filter_map do |track, match|
        next unless track.preview
        next if track.id == seed.id

        title = TitleCleaner.normalize(track.title)
        artist = TitleCleaner.normalize(track.artist)
        # Covers, sped-up edits and remasters of the seed are the same song, not a similar one.
        next if title == seed_title

        key = "#{artist}|#{title}"
        next if seen[key]
        next if per_artist[artist] >= @per_artist

        seen[key] = true
        per_artist[artist] += 1
        track.to_h.merge(match: match.round(4), audio: nil, score: match.round(4))
      end
    end

    def apply_audio_scores(seed, items)
      tracks = items.map { |item| Track.new(id: item[:id], preview: item[:preview]) }
      audio = @reranker.scores(seed, tracks)
      raise UpstreamError, "the worker returned no scores" if audio.empty?

      match_scale = scale(items.map { |item| item[:match] })
      audio_scale = scale(audio.values)
      missing = median(audio.values.map { |value| audio_scale.call(value) })

      items.map do |item|
        raw = audio[item[:id].to_s]
        audio_part = raw ? audio_scale.call(raw) : missing
        blended = ((1 - @rerank_weight) * match_scale.call(item[:match])) + (@rerank_weight * audio_part)
        item.merge(audio: raw&.round(4), score: blended.round(4))
      end.sort_by { |item| -item[:score] }
    end

    # Min-max scaling to 0..1 so listening data and audio similarity are comparable.
    def scale(values)
      low, high = values.minmax
      span = high - low
      ->(value) { span.zero? ? 1.0 : (value - low) / span }
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    # Order-preserving map over a small thread pool. A lookup that fails
    # upstream just drops that candidate instead of failing the whole search.
    def parallel_map(items)
      results = Array.new(items.size)
      queue = Queue.new
      items.each_with_index { |item, index| queue << [item, index] }
      queue.close

      Array.new([@threads, items.size].min) do
        Thread.new do
          while (pair = queue.pop)
            item, index = pair
            results[index] = begin
              yield item
            rescue UpstreamError
              nil
            end
          end
        end
      end.each(&:join)
      results
    end
  end
end
