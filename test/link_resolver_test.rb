# frozen_string_literal: true

require_relative "test_helper"

# Every ID in these links is made up for the test; none is a real catalogue ID.
class LinkResolverTest < Minitest::Test
  SEED =Fixtures.deezer_track(id: 100_000_001, title: "we fell in love in october", artist: "girl in red")

  def setup
    @http = FakeHTTP.new
    @resolver = Soundalike::LinkResolver.new(http: @http, deezer: Soundalike::Deezer.new(http: @http))
  end

  def stub_search(result = SEED)
    @http.stub("https://api.deezer.com/search", json: { "data" => result ? [result] : [] })
  end

  def test_youtube_watch_link
    @http.stub("https://www.youtube.com/oembed",
               json: { "title" => "girl in red - we fell in love in october (Official Video)",
                       "author_name" => "girl in red" })
    stub_search

    track = @resolver.resolve("https://www.youtube.com/watch?v=AbCdEfGhIjK&list=PLabc")

    assert_equal "we fell in love in october", track.title
    assert_equal "girl in red", track.artist
    oembed = @http.calls.first
    assert_equal "https://www.youtube.com/watch?v=AbCdEfGhIjK", oembed.params[:url],
                 "only the video ID is forwarded, never the pasted URL"
    search = @http.calls.last
    assert_equal 'artist:"girl in red" track:"we fell in love in october"', search.params[:q]
  end

  def test_youtube_short_link_without_scheme
    @http.stub("https://www.youtube.com/oembed", json: { "title" => "Birch Tree", "author_name" => "Strawberry Guy - Topic" })
    stub_search(Fixtures.deezer_track(id: 2, title: "Birch Tree", artist: "Strawberry Guy"))

    assert_equal "Birch Tree", @resolver.resolve("youtu.be/abcdefghijk?t=10").title
    assert_equal "https://www.youtube.com/watch?v=abcdefghijk", @http.calls.first.params[:url]
  end

  def test_youtube_music_and_shorts_links
    @http.stub("https://www.youtube.com/oembed", json: { "title" => "a - b", "author_name" => "a" })
    stub_search

    @resolver.resolve("https://music.youtube.com/watch?v=AAAAAAAAAAA&si=x")
    @resolver.resolve("https://www.youtube.com/shorts/BBBBBBBBBBB")

    urls = @http.calls.select { |call| call.url.include?("oembed") }.map { |call| call.params[:url] }
    assert_equal %w[https://www.youtube.com/watch?v=AAAAAAAAAAA https://www.youtube.com/watch?v=BBBBBBBBBBB], urls
  end

  def test_youtube_private_video
    @http.stub("https://www.youtube.com/oembed", status: 401, json: nil)
    error = assert_raises(Soundalike::NotFound) { @resolver.resolve("https://youtu.be/abcdefghijk") }
    assert_match(/private or removed/, error.message)
  end

  def test_youtube_playlist_link_is_rejected
    assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://www.youtube.com/playlist?list=PL123") }
    assert_empty @http.calls
  end

  def test_youtube_title_that_matches_nothing_retries_on_title_alone
    @http.stub("https://www.youtube.com/oembed", json: { "title" => "Obscure Jam", "author_name" => "Some Uploader" })
    queries = []
    @http.stub("https://api.deezer.com/search", json: lambda { |params, _|
      queries << params[:q]
      { "data" => [] }
    })

    error = assert_raises(Soundalike::NotFound) { @resolver.resolve("https://youtu.be/abcdefghijk") }
    assert_match(/Type the artist and title/, error.message)
    assert_equal ['artist:"Some Uploader" track:"Obscure Jam"', "Some Uploader Obscure Jam", "Obscure Jam"], queries
  end

  def test_deezer_track_link
    @http.stub("https://api.deezer.com/track/100000001", json: SEED)
    track = @resolver.resolve("https://www.deezer.com/us/track/100000001?utm=x")
    assert_equal 100_000_001, track.id
    assert_equal "https://cdnt-preview.dzcdn.net/100000001.mp3", track.preview
  end

  def test_deezer_missing_track
    @http.stub("https://api.deezer.com/track/1", json: { "error" => { "type" => "DataException", "message" => "no data", "code" => 800 } })
    assert_raises(Soundalike::NotFound) { @resolver.resolve("https://deezer.com/track/1") }
  end

  def test_deezer_album_link_is_rejected
    assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://www.deezer.com/album/123") }
  end

  def test_apple_music_album_link_with_track_parameter
    @http.stub("https://itunes.apple.com/lookup",
               json: { "results" => [{ "wrapperType" => "track", "artistName" => "girl in red",
                                       "trackName" => "we fell in love in october" }] })
    stub_search

    track = @resolver.resolve("https://music.apple.com/us/album/we-fell-in-love-in-october/1000000001?i=1000000002")

    assert_equal "girl in red", track.artist
    assert_equal({ id: "1000000002", entity: "song", country: "us" }, @http.calls.first.params)
  end

  def test_apple_music_song_link
    @http.stub("https://itunes.apple.com/lookup",
               json: { "results" => [{ "wrapperType" => "track", "artistName" => "a", "trackName" => "b" }] })
    stub_search
    @resolver.resolve("https://music.apple.com/gb/song/tired/1000000003")
    assert_equal "1000000003", @http.calls.first.params[:id]
    assert_equal "gb", @http.calls.first.params[:country]
  end

  def test_apple_music_album_without_track_is_rejected
    assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://music.apple.com/us/album/chapter-1/1000000004") }
  end

  def test_soundcloud_track_link
    @http.stub("https://soundcloud.com/oembed", json: { "title" => "we fell in love in october by girl in red", "author_name" => "girl in red" })
    stub_search

    track = @resolver.resolve("https://soundcloud.com/girlinred/we-fell-in-love-in-october?si=abc")

    assert_equal "we fell in love in october", track.title
    assert_equal "https://soundcloud.com/girlinred/we-fell-in-love-in-october", @http.calls.first.params[:url]
  end

  def test_soundcloud_playlist_is_rejected
    assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://soundcloud.com/girlinred/sets/chapter-1") }
  end

  def test_spotify_links_get_a_clear_message
    error = assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://open.spotify.com/track/madeUpTrackId") }
    assert_match(/Spotify links are not supported/, error.message)
    assert_empty @http.calls
  end

  def test_unknown_hosts_are_rejected_without_any_request
    error = assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("http://169.254.169.254/latest/meta-data") }
    assert_match(/169\.254\.169\.254 are not supported/, error.message)
    assert_empty @http.calls
  end

  def test_plain_text_with_artist_and_title
    stub_search
    @resolver.resolve("girl in red - we fell in love in october")
    assert_equal 'artist:"girl in red" track:"we fell in love in october"', @http.calls.first.params[:q]
  end

  def test_plain_text_free_search
    stub_search
    @resolver.resolve("we fell in love in october")
    assert_equal "we fell in love in october", @http.calls.first.params[:q]
  end

  def test_plain_text_with_no_match
    stub_search(nil)
    assert_raises(Soundalike::NotFound) { @resolver.resolve("zzzz qqqq") }
  end

  def test_empty_and_oversized_input
    assert_raises(Soundalike::BadInput) { @resolver.resolve("   ") }
    assert_raises(Soundalike::BadInput) { @resolver.resolve(nil) }
    assert_raises(Soundalike::BadInput) { @resolver.resolve("a" * 501) }
  end

  def test_malformed_url
    assert_raises(Soundalike::BadInput) { @resolver.resolve("https://youtu.be/[bad") }
    assert_raises(Soundalike::BadInput) { @resolver.resolve("https://youtube.com/watch?v=%zz") }
  end

  def test_video_id_with_odd_characters_is_refused_before_any_request
    assert_raises(Soundalike::UnsupportedLink) { @resolver.resolve("https://youtube.com/watch?v=a b|c") }
    assert_empty @http.calls
  end
end
