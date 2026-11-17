# frozen_string_literal: true

module Soundalike
  # Turns messy video and upload titles into an artist and a song title.
  #
  #   "girl in red - we fell in love in october (Official Video)"
  #     => { artist: "girl in red", title: "we fell in love in october" }
  module TitleCleaner
    NOISE_WORDS = /official|video|audio|lyrics?|visuali[sz]er|hd|hq|4k|remaster(?:ed)?|m\/?v|explicit|clean version|full song|out now/i
    BRACKETED_NOISE = /\s*[(\[][^)\]]*\b(?:#{NOISE_WORDS.source})\b[^)\]]*[)\]]/i
    BRACKETED_FEAT = /\s*[(\[]\s*(?:feat\.?|ft\.?|featuring)\b[^)\]]*[)\]]/i
    TRAILING_FEAT = /\s+(?:feat\.?|ft\.?|featuring)\s+.*\z/i
    DASH = /\s+[-–—]\s+/
    PIPE = %r{\s+(?:\||//)\s+}
    QUOTES = /\A["'“‘](.*)["'”’]\z/
    CHANNEL_SUFFIX = /\s*(?:-\s*Topic|VEVO|Official)\z/i

    module_function

    # title: the upload title. channel: the uploader name, used when the title
    # holds no artist. Returns { artist:, title: }; artist may be nil.
    def parse(title, channel = nil)
      text = strip_noise(title.to_s)
      channel = channel.to_s.strip

      if channel.match?(/-\s*Topic\z/i)
        # YouTube's auto-generated "Artist - Topic" channels title uploads with the song name only.
        return { artist: clean_channel(channel), title: clean_title(text) }
      end

      artist, song = split(text)
      return { artist: clean_artist(artist), title: clean_title(song) } if artist

      { artist: channel.empty? ? nil : clean_channel(channel), title: clean_title(text) }
    end

    # Splits "Artist - Title" on the first spaced dash. Returns [nil, text] when there is none.
    def split(text)
      artist, song = text.to_s.strip.split(DASH, 2)
      return [nil, text.to_s.strip] if song.nil? || artist.strip.empty? || song.strip.empty?

      [artist.strip, song.strip]
    end

    def strip_noise(text)
      text = text.strip
      # "Song | Official Video": keep what comes before the first separator when the rest is noise.
      head, tail = text.split(PIPE, 2)
      text = head if tail && tail.match?(NOISE_WORDS)
      text.gsub(BRACKETED_NOISE, "").strip
    end

    def clean_title(text)
      text = text.gsub(BRACKETED_FEAT, "").sub(TRAILING_FEAT, "").strip
      text = Regexp.last_match(1).strip if text =~ QUOTES
      text
    end

    def clean_artist(text)
      text.sub(TRAILING_FEAT, "").strip
    end

    def clean_channel(text)
      text.sub(CHANNEL_SUFFIX, "").strip
    end

    # Comparison key: lower-case, no bracketed parts, no version suffixes, no punctuation.
    def normalize(text)
      text.to_s.downcase
          .gsub(/[(\[][^)\]]*[)\]]/, " ")
          .sub(/\s+-\s+(?:sped up|slowed|remaster|live|acoustic|radio edit|single version|mono|stereo).*\z/, "")
          .gsub(/[^\p{L}\p{N}]+/, " ")
          .strip
    end
  end
end
