# frozen_string_literal: true

module Soundalike
  # Turns whatever the user pasted into one canonical Deezer track.
  #
  # A link is only ever used to *identify* the song. The pasted URL itself is
  # never fetched: the resolver extracts an ID or path from it and calls a
  # fixed, known endpoint (YouTube oEmbed, iTunes lookup, SoundCloud oEmbed,
  # Deezer). That keeps user input from steering server-side requests.
  class LinkResolver
    MAX_INPUT = 500
    KNOWN_HOSTS = /\A(?:[a-z]+\.)?(?:youtube\.com|youtu\.be|deezer\.com|apple\.com|soundcloud\.com|spotify\.com|spotify\.link)\//i
    YOUTUBE_ID = /\A[\w-]{6,20}\z/
    HOW_TO = "Paste a YouTube, Apple Music, Deezer or SoundCloud link, or type the artist and title."

    def initialize(http:, deezer:)
      @http = http
      @deezer = deezer
    end

    def resolve(input)
      text = input.to_s.strip
      raise BadInput, HOW_TO if text.empty?
      raise BadInput, "That is too long to be a song link. #{HOW_TO}" if text.length > MAX_INPUT

      uri = to_uri(text)
      uri ? resolve_url(uri) : resolve_text(text)
    end

    private

    def to_uri(text)
      text = "https://#{text}" if !text.match?(%r{\Ahttps?://}i) && text.match?(KNOWN_HOSTS)
      return nil unless text.match?(%r{\Ahttps?://}i)

      uri = URI.parse(text)
      uri.host ? uri : nil
    rescue URI::InvalidURIError
      raise BadInput, "That link could not be read. #{HOW_TO}"
    end

    def resolve_url(uri)
      host = uri.host.downcase.sub(/\A(?:www|m)\./, "")
      case host
      when "youtube.com", "music.youtube.com", "youtu.be" then from_youtube(uri, host)
      when "deezer.com" then from_deezer(uri)
      when "music.apple.com" then from_apple(uri)
      when "soundcloud.com" then from_soundcloud(uri)
      when "open.spotify.com", "spotify.link", "spotify.com"
        raise UnsupportedLink, "Spotify links are not supported. #{HOW_TO}"
      when "link.deezer.com", "deezer.page.link", "on.soundcloud.com"
        raise UnsupportedLink, "Short share links are not supported. Open it and copy the full track link."
      else
        raise UnsupportedLink, "Links from #{host} are not supported. #{HOW_TO}"
      end
    end

    def resolve_text(text)
      artist, title = TitleCleaner.split(text)
      track = artist ? @deezer.search(artist: artist, title: title) : @deezer.search_text(text)
      track or raise NotFound, "No song found for “#{text}”. Try “artist - title”."
    end

    # --- YouTube ---------------------------------------------------------

    def from_youtube(uri, host)
      id = youtube_id(uri, host)
      raise UnsupportedLink, "That YouTube link is not a single video. Paste a video link." unless id&.match?(YOUTUBE_ID)

      response = @http.get("https://www.youtube.com/oembed",
                           url: "https://www.youtube.com/watch?v=#{id}", format: "json")
      data = response.json
      unless response.ok? && data.is_a?(Hash) && data["title"]
        raise NotFound, "That YouTube video could not be read. It may be private or removed."
      end

      match_upload(data["title"], data["author_name"], "video")
    end

    def youtube_id(uri, host)
      segments = uri.path.to_s.split("/").reject(&:empty?)
      return segments.first if host == "youtu.be"
      return URI.decode_www_form(uri.query.to_s).to_h["v"] if segments.first == "watch"
      return segments[1] if %w[shorts embed live v].include?(segments.first)

      nil
    end

    # --- Deezer ----------------------------------------------------------

    def from_deezer(uri)
      id = uri.path.to_s[%r{/track/(\d+)}, 1]
      raise UnsupportedLink, "That Deezer link is not a track. Paste a link to one song." unless id

      @deezer.track(id) or raise NotFound, "Deezer has no track with that link."
    end

    # --- Apple Music -----------------------------------------------------

    def from_apple(uri)
      id = URI.decode_www_form(uri.query.to_s).to_h["i"] || uri.path.to_s[%r{/song/(?:[^/]+/)?(\d+)}, 1]
      unless id&.match?(/\A\d+\z/)
        raise UnsupportedLink, "That Apple Music link is an album or playlist. Paste a link to one song."
      end

      params = { id: id, entity: "song" }
      storefront = uri.path.to_s[%r{\A/([a-z]{2})/}i, 1]
      params[:country] = storefront.downcase if storefront

      response = @http.get("https://itunes.apple.com/lookup", params)
      results = response.json.is_a?(Hash) ? Array(response.json["results"]) : []
      song = results.find { |item| item["wrapperType"] == "track" && item["trackName"] }
      raise NotFound, "Apple Music has no song with that link." unless response.ok? && song

      @deezer.search(artist: song["artistName"], title: TitleCleaner.clean_title(song["trackName"])) or
        raise NotFound, no_match(song["trackName"], song["artistName"])
    end

    # --- SoundCloud ------------------------------------------------------

    def from_soundcloud(uri)
      segments = uri.path.to_s.split("/").reject(&:empty?)
      unless segments.size == 2 && segments.none? { |part| %w[sets discover search].include?(part) }
        raise UnsupportedLink, "That SoundCloud link is not a single track. Paste a link to one song."
      end

      response = @http.get("https://soundcloud.com/oembed",
                           url: "https://soundcloud.com/#{segments.join('/')}", format: "json")
      data = response.json
      unless response.ok? && data.is_a?(Hash) && data["title"]
        raise NotFound, "That SoundCloud track could not be read. It may be private or removed."
      end

      uploader = data["author_name"].to_s
      # SoundCloud formats oEmbed titles as "Track by Uploader".
      title = data["title"].sub(/\s+by\s+#{Regexp.escape(uploader)}\z/i, "")
      match_upload(title, uploader, "track")
    end

    # --- shared ----------------------------------------------------------

    def match_upload(raw_title, uploader, kind)
      parsed = TitleCleaner.parse(raw_title, uploader)
      track = @deezer.search(artist: parsed[:artist], title: parsed[:title])
      # Uploader names are often not the artist; retry on the title alone.
      track ||= @deezer.search_text(parsed[:title]) if parsed[:artist]
      track or raise NotFound,
                     "Found the #{kind} (“#{raw_title}”) but could not match it to a song. " \
                     "Type the artist and title instead."
    end

    def no_match(title, artist)
      "Found “#{title}” by #{artist} but could not match it in the catalogue used for previews."
    end
  end
end
