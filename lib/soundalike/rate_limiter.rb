# frozen_string_literal: true

module Soundalike
  # Sliding-window limiter: at most `limit` calls in any `per` seconds.
  # Callers block in #wait until a slot frees up.
  #
  # It only knows about this process. Deezer counts requests per IP address,
  # so several processes behind one address need a shared limiter instead.
  class RateLimiter
    def initialize(limit:, per:,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(seconds) { sleep(seconds) })
      @limit = limit
      @per = per
      @clock = clock
      @sleeper = sleeper
      @stamps = []
      @mutex = Mutex.new
    end

    def wait
      loop do
        delay = @mutex.synchronize do
          now = @clock.call
          @stamps.shift while @stamps.first && @stamps.first <= now - @per
          if @stamps.size < @limit
            @stamps << now
            nil
          else
            @stamps.first + @per - now
          end
        end
        return unless delay

        @sleeper.call(delay)
      end
    end
  end
end
