# frozen_string_literal: true

module Soundalike
  # Thread-safe in-memory cache with a time-to-live and a size cap.
  #
  # Deezer preview URLs are signed and expire, so entries holding them must
  # stay short-lived. Swap this for Redis or a database table when the app
  # runs on more than one process.
  class Cache
    def initialize(ttl: 600, max_entries: 500, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @ttl = ttl
      @max_entries = max_entries
      @clock = clock
      @store = {}
      @mutex = Mutex.new
    end

    def fetch(key)
      cached = read(key)
      return cached unless cached.nil?

      value = yield
      write(key, value) unless value.nil?
      value
    end

    def read(key)
      @mutex.synchronize do
        entry = @store[key]
        next nil unless entry

        if entry[:expires_at] <= @clock.call
          @store.delete(key)
          next nil
        end
        entry[:value]
      end
    end

    def write(key, value)
      @mutex.synchronize do
        @store.delete(key)
        @store[key] = { value: value, expires_at: @clock.call + @ttl }
        @store.shift while @store.size > @max_entries
      end
      value
    end

    def size = @mutex.synchronize { @store.size }
  end
end
