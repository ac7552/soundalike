# frozen_string_literal: true

require_relative "test_helper"

class TitleCleanerTest < Minitest::Test
  TC = Soundalike::TitleCleaner

  def test_splits_artist_and_title_and_drops_video_noise
    parsed = TC.parse("girl in red - we fell in love in october (Official Video)", "girl in red")
    assert_equal({ artist: "girl in red", title: "we fell in love in october" }, parsed)
  end

  def test_handles_square_brackets_and_en_dash
    parsed = TC.parse("beabadoobee – If You Want To [Official Audio]", "beabadoobee")
    assert_equal({ artist: "beabadoobee", title: "If You Want To" }, parsed)
  end

  def test_topic_channels_use_the_channel_as_artist
    parsed = TC.parse("Birch Tree", "Strawberry Guy - Topic")
    assert_equal({ artist: "Strawberry Guy", title: "Birch Tree" }, parsed)
  end

  def test_falls_back_to_channel_when_title_has_no_dash
    parsed = TC.parse("Tired (Lyrics)", "beabadoobeeVEVO")
    assert_equal({ artist: "beabadoobee", title: "Tired" }, parsed)
  end

  def test_no_channel_and_no_dash_leaves_artist_nil
    assert_equal({ artist: nil, title: "Space Girl" }, TC.parse("Space Girl"))
  end

  def test_strips_featured_artists
    parsed = TC.parse("Peachy! feat. mxmtoon - Falling for U (feat. mxmtoon) (Official Video)")
    assert_equal({ artist: "Peachy!", title: "Falling for U" }, parsed)
  end

  def test_keeps_meaningful_brackets
    parsed = TC.parse("Taylor Swift - All Too Well (Taylor's Version)")
    assert_equal "All Too Well (Taylor's Version)", parsed[:title]
  end

  def test_drops_noise_after_a_pipe
    parsed = TC.parse("Cavetown - Juliet | Official Music Video")
    assert_equal({ artist: "Cavetown", title: "Juliet" }, parsed)
  end

  def test_keeps_text_after_a_pipe_when_it_is_not_noise
    assert_equal "Part One | Part Two", TC.parse("Part One | Part Two")[:title]
  end

  def test_strips_wrapping_quotes
    assert_equal "Francis Forever", TC.parse("Mitski - \"Francis Forever\"")[:title]
  end

  def test_hyphenated_words_are_not_split
    assert_equal [nil, "Jay-Z"], TC.split("Jay-Z")
  end

  def test_normalize_ignores_case_punctuation_and_version_suffixes
    assert_equal "we fell in love in october", TC.normalize("We Fell In Love In October - Sped Up")
    assert_equal "we fell in love in october", TC.normalize("we fell in love in october (TikTok Remix)")
    assert_equal "dream ivory", TC.normalize("Dream, Ivory")
    assert_equal "beyoncé", TC.normalize("Beyoncé")
  end
end
