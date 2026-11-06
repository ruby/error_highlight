module ErrorHighlight
  class DefaultFormatter
    MIN_SNIPPET_WIDTH = 20

    def self.message_for(spot)
      # currently only a one-line code snippet is supported
      return "" unless spot[:first_lineno] == spot[:last_lineno]

      snippet      = spot[:snippet]
      first_column = spot[:first_column]
      last_column  = spot[:last_column]
      ellipsis     = "..."

      # truncate snippet to fit in the viewport
      if max_snippet_width && snippet.size > max_snippet_width
        available_width = max_snippet_width - ellipsis.size
        center          = first_column - max_snippet_width / 2

        visible_start  = last_column < available_width ? 0 : [center, 0].max
        visible_end    = visible_start + max_snippet_width
        visible_start  = snippet.size - max_snippet_width if visible_end > snippet.size

        prefix = visible_start.positive?    ? ellipsis : ""
        suffix = visible_end < snippet.size ? ellipsis : ""

        snippet = prefix + snippet[(visible_start + prefix.size)...(visible_end - suffix.size)] + suffix
        snippet << "\n" unless snippet.end_with?("\n")

        first_column -= visible_start
        last_column  = [last_column - visible_start, snippet.size - 1].min
      end

      indent = snippet[0...first_column].gsub(/[^\t]/, " ")
      marker = indent + "^" * (last_column - first_column)

      "\n\n#{ snippet }#{ marker }"
    end

    def self.max_snippet_width
      return if LocalSettings[:max_snippet_width] == :disabled

      LocalSettings[:max_snippet_width] ||= terminal_width
    end

    def self.max_snippet_width=(width)
      return LocalSettings[:max_snippet_width] = :disabled if width.nil?

      width = width.to_i

      if width < MIN_SNIPPET_WIDTH
        warn "'max_snippet_width' adjusted to minimum value of #{MIN_SNIPPET_WIDTH}."
        width = MIN_SNIPPET_WIDTH
      end

      LocalSettings[:max_snippet_width] = width
    end

    def self.terminal_width
      # lazy load io/console to avoid loading it when 'max_snippet_width' is manually set
      require "io/console"
      $stderr.winsize[1] if $stderr.tty?
    rescue LoadError, NoMethodError, SystemCallError
      # skip truncation when terminal window size is unavailable
    end
  end

  # The formatter settings are Ractor-local. On Ruby implementations without
  # Ractor (e.g., JRuby), they are module instance variables instead, which are
  # likewise shared by all threads. Unlike Hash, which is not thread-safe on
  # JRuby, concurrent instance variable updates are serialized
  # (https://github.com/jruby/jruby/wiki/Concurrency-in-jruby), so threads
  # formatting errors concurrently cannot corrupt the settings.
  module LocalSettings
    RACTOR_KEYS = {
      formatter: :__error_highlight_formatter__,
      max_snippet_width: :__error_highlight_max_snippet_width__,
    }.freeze

    if defined?(Ractor)
      def self.[](name)
        Ractor.current[RACTOR_KEYS.fetch(name)]
      end

      def self.[]=(name, value)
        Ractor.current[RACTOR_KEYS.fetch(name)] = value
      end
    else
      IVARS = RACTOR_KEYS.to_h { |name, _| [name, :"@#{ name }"] }.freeze

      def self.[](name)
        instance_variable_get(IVARS.fetch(name))
      end

      def self.[]=(name, value)
        instance_variable_set(IVARS.fetch(name), value)
      end
    end
  end
  private_constant :LocalSettings

  def self.formatter
    LocalSettings[:formatter] || DefaultFormatter
  end

  def self.formatter=(formatter)
    LocalSettings[:formatter] = formatter
  end
end
