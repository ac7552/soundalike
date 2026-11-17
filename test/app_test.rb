# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Drives the Rack app end to end with a fake HTTP client behind the real
# resolver, recommender and API clients.
class AppTest < Minitest::Test
  SEED = Fixtures.deezer_track(id: 100, title: "we fell in love in october", artist: "girl in red", artist_id: 9)

  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "index.html"), "<h1>home</h1>")
    File.write(File.join(@dir, "app.js"), "console.log(1)")
    File.write(File.join(File.dirname(@dir), "secret-#{File.basename(@dir)}.txt"), "secret")
    @http = FakeHTTP.new
    @errors = StringIO.new
  end

  def teardown
    FileUtils.rm_f(File.join(File.dirname(@dir), "secret-#{File.basename(@dir)}.txt"))
    FileUtils.remove_entry(@dir)
  end

  def app(env = {})
    Soundalike.build_app(public_dir: @dir, env: env, http: @http)
  end

  def request(app, method, path, body: "", content_type: nil, headers: {})
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => "",
      "rack.input" => StringIO.new(body), "rack.errors" => @errors,
      "CONTENT_LENGTH" => body.bytesize.to_s
    }
    env["CONTENT_TYPE"] = content_type if content_type
    status, response_headers, chunks = app.call(env.merge(headers))
    [status, response_headers, chunks.join]
  end

  def post_json(app, path, payload)
    status, headers, body = request(app, "POST", path, body: JSON.generate(payload), content_type: "application/json")
    [status, headers, JSON.parse(body)]
  end

  def stub_catalogue
    @http.stub("https://www.youtube.com/oembed",
               json: { "title" => "girl in red - we fell in love in october", "author_name" => "girl in red" })
    @http.stub(Soundalike::Lastfm::BASE, json: { "similartracks" => { "track" => [
                 { "name" => "Birch Tree", "match" => 1.0, "artist" => { "name" => "Strawberry Guy" } },
                 { "name" => "Tired", "match" => 0.7, "artist" => { "name" => "beabadoobee" } }
               ] } })
    @http.stub("https://api.deezer.com/track/100", json: SEED)
    @http.stub("https://api.deezer.com/search", json: lambda { |params, _|
      found = case params[:q]
              when /october/ then SEED
              when /Birch Tree/ then Fixtures.deezer_track(id: 1, title: "Birch Tree", artist: "Strawberry Guy")
              when /Tired/ then Fixtures.deezer_track(id: 2, title: "Tired", artist: "beabadoobee")
              end
      { "data" => [found].compact }
    })
  end

  # --- static files ------------------------------------------------------

  def test_serves_the_page_with_security_headers
    status, headers, body = request(app, "GET", "/")
    assert_equal 200, status
    assert_equal "<h1>home</h1>", body
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    assert_equal "nosniff", headers["x-content-type-options"]
    assert_includes headers["content-security-policy"], "default-src 'self'"
    assert_equal headers.keys, headers.keys.map(&:downcase), "Rack 3 requires lower-case header names"
  end

  def test_serves_assets_and_answers_head_without_a_body
    status, headers, body = request(app, "GET", "/app.js")
    assert_equal [200, "text/javascript; charset=utf-8", "console.log(1)"], [status, headers["content-type"], body]

    status, headers, body = request(app, "HEAD", "/app.js")
    assert_equal [200, "14", ""], [status, headers["content-length"], body]
  end

  def test_refuses_paths_outside_the_public_folder
    secret = "/../secret-#{File.basename(@dir)}.txt"
    assert_equal 404, request(app, "GET", secret).first
    assert_equal 404, request(app, "GET", "/..#{secret}").first
    assert_equal 404, request(app, "GET", "/missing.css").first
    assert_equal 404, request(app, "GET", "/app.js\0.html").first
    assert_equal 404, request(app, "GET", "/subdir").first
  end

  def test_the_real_public_folder_holds_the_page_and_its_assets
    real = Soundalike.build_app(public_dir: File.expand_path("../public", __dir__), env: {}, http: @http)
    { "/" => "text/html; charset=utf-8", "/app.js" => "text/javascript; charset=utf-8",
      "/style.css" => "text/css; charset=utf-8" }.each do |path, type|
      status, headers, body = request(real, "GET", path)
      assert_equal [200, type], [status, headers["content-type"]], path
      refute_empty body
    end
    _, _, page = request(real, "GET", "/")
    assert_includes page, 'src="/app.js"'
    assert_includes page, 'href="/style.css"'
  end

  def test_unknown_api_route_and_wrong_method
    assert_equal 404, request(app, "GET", "/api/nope").first
    assert_equal 404, request(app, "GET", "/api/similar").first
    assert_equal 405, request(app, "DELETE", "/").first
  end

  # --- /api/config -------------------------------------------------------

  def test_config_reflects_environment
    _, _, body = request(app, "GET", "/api/config")
    assert_equal({ "listen" => false, "rerank" => false }, JSON.parse(body))

    _, _, body = request(app("AUDD_API_TOKEN" => "t", "RERANK_URL" => "http://127.0.0.1:4100"), "GET", "/api/config")
    assert_equal({ "listen" => true, "rerank" => true }, JSON.parse(body))
  end

  # --- /api/similar ------------------------------------------------------

  def test_similar_from_a_youtube_link
    stub_catalogue
    status, headers, body = post_json(app("LASTFM_API_KEY" => "k"), "/api/similar", input: "https://youtu.be/abcdefghijk")

    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    assert_equal "no-store", headers["cache-control"]
    assert_equal "girl in red", body["seed"]["artist"]
    assert_equal "lastfm", body["source"]
    assert_equal [["Birch Tree", 1], ["Tired", 2]], body["results"].map { |item| item.values_at("title", "rank") }
    assert_equal "https://cdnt-preview.dzcdn.net/1.mp3", body["results"][0]["preview"]
    assert_equal false, body["reranked"]
  end

  def test_similar_with_rerank
    stub_catalogue
    @http.stub("http://127.0.0.1:4100/scores", json: { "scores" => { "1" => 0.1, "2" => 0.9 } })
    env = { "LASTFM_API_KEY" => "k", "RERANK_URL" => "http://127.0.0.1:4100", "RERANK_WEIGHT" => "1" }

    _, _, body = post_json(app(env), "/api/similar", input: "https://www.deezer.com/track/100", rerank: true)

    assert_equal true, body["reranked"]
    assert_equal %w[Tired Birch\ Tree], body["results"].map { |item| item["title"] }
  end

  def test_similar_reports_bad_input_and_unsupported_links
    status, _, body = post_json(app, "/api/similar", input: "")
    assert_equal 400, status
    assert_match(/Paste a YouTube/, body["error"])

    status, _, body = post_json(app, "/api/similar", input: "https://open.spotify.com/track/x")
    assert_equal 422, status
    assert_match(/Spotify/, body["error"])
  end

  def test_similar_rejects_bad_json_and_oversized_bodies
    status, _, body = request(app, "POST", "/api/similar", body: "{nope")
    assert_equal 400, status
    assert_equal "Send a JSON object.", JSON.parse(body)["error"]

    assert_equal 400, request(app, "POST", "/api/similar", body: "[1]").first
    assert_equal 413, request(app, "POST", "/api/similar", body: "x" * (16 * 1024 + 1)).first
    # A lying Content-Length must not get a large body past the limit.
    big = "x" * (16 * 1024 + 1)
    assert_equal 413, request(app, "POST", "/api/similar", body: big, headers: { "CONTENT_LENGTH" => "10" }).first
  end

  def test_upstream_failures_become_502_and_unexpected_errors_500_without_leaking
    @http.stub("https://api.deezer.com/search", raises: Soundalike::UpstreamError.new("Could not reach api.deezer.com (ReadTimeout)."))
    status, _, body = post_json(app, "/api/similar", input: "some song")
    assert_equal 502, status
    assert_match(/api\.deezer\.com/, body["error"])

    broken = FakeHTTP.new.stub("https://api.deezer.com/search", raises: RuntimeError.new("secret detail"))
    status, _, body = post_json(Soundalike.build_app(public_dir: @dir, env: {}, http: broken), "/api/similar", input: "some song")
    assert_equal 500, status
    assert_equal "Something went wrong on the server.", body["error"]
    assert_match(/secret detail/, @errors.string, "the detail goes to the server log only")
  end

  # --- /api/recognize ----------------------------------------------------

  def test_recognize_is_off_without_a_token
    status, _, body = request(app, "POST", "/api/recognize", body: "audio", content_type: "audio/webm")
    assert_equal 501, status
    assert_match(/switched off/, JSON.parse(body)["error"])
    assert_empty @http.calls
  end

  def test_recognize_identifies_the_clip_and_returns_similar_songs
    stub_catalogue
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => {
                 "artist" => "girl in red", "title" => "we fell in love in october", "deezer" => { "id" => 100 }
               } })

    status, _, body = request(app("AUDD_API_TOKEN" => "t", "LASTFM_API_KEY" => "k"), "POST", "/api/recognize",
                              body: "audio-bytes", content_type: "audio/webm;codecs=opus")

    assert_equal 200, status
    parsed = JSON.parse(body)
    assert_equal 100, parsed["seed"]["id"]
    assert_equal ["Birch Tree", "Tired"], parsed["results"].map { |item| item["title"] }
    upload = @http.calls.find { |call| call.verb == :post_multipart }
    assert_equal "audio-bytes", upload.payload[2][1].read
  end

  def test_recognize_falls_back_to_search_when_audd_gives_no_deezer_id
    stub_catalogue
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => { "artist" => "girl in red", "title" => "we fell in love in october" } })
    status, _, body = request(app("AUDD_API_TOKEN" => "t", "LASTFM_API_KEY" => "k"), "POST", "/api/recognize",
                              body: "audio", content_type: "audio/mp4")
    assert_equal [200, 100], [status, JSON.parse(body)["seed"]["id"]]
  end

  def test_recognize_no_match_empty_and_oversized
    @http.stub(Soundalike::Audd::URL, json: { "status" => "success", "result" => nil })
    listening = app("AUDD_API_TOKEN" => "t")

    status, _, body = request(listening, "POST", "/api/recognize", body: "audio", content_type: "audio/webm")
    assert_equal 404, status
    assert_match(/Could not recognise/, JSON.parse(body)["error"])

    assert_equal 400, request(listening, "POST", "/api/recognize", body: "").first
    assert_equal 413, request(listening, "POST", "/api/recognize", body: "x" * (3 * 1024 * 1024 + 1)).first
  end
end
