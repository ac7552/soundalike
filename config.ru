# frozen_string_literal: true

# Start with:  bundle exec puma -p 9292
require_relative "lib/soundalike"

Soundalike::Env.load(File.join(__dir__, ".env"))

run Soundalike.build_app(public_dir: File.join(__dir__, "public"))
