require_relative "formatter"

module ErrorHighlight
  module CoreExt
    # This is a marker to let `DidYouMean::Correctable#original_message` skip
    # the following method definition of `to_s`.
    # See https://github.com/ruby/did_you_mean/pull/152
    SKIP_TO_S_FOR_SUPER_LOOKUP = true
    private_constant :SKIP_TO_S_FOR_SUPER_LOOKUP

    def self.apply(error_class)
      error_class.alias_method(:message, :to_s)
      error_class.prepend(self)
    end

    def to_s
      msg = super.dup

      locs = backtrace_locations
      return msg unless locs

      loc = locs.first
      begin
        node = RubyVM::AbstractSyntaxTree.of(loc, save_script_lines: true)
        opts = {}

        case self
        when NoMethodError, NameError
          opts[:point_type] = :name
          opts[:name] = name
        when TypeError, ArgumentError
          opts[:point_type] = :args
        end

        spot = ErrorHighlight.spot(node, **opts)

      rescue Errno::ENOENT, SyntaxError
      end

      if spot
        points = ErrorHighlight.formatter.message_for(spot)
        msg << points if !msg.include?(points)
      end

      msg
    end
  end

  CoreExt.apply(NameError)

  # The extension for TypeError/ArgumentError is temporarily disabled due to many test failures

  # CoreExt.apply(TypeError)
  # CoreExt.apply(ArgumentError)
end
