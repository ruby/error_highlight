require "prism"
require_relative "version"

module ErrorHighlight
  # Identify the code fragment where a given exception occurred.
  #
  # Options:
  #
  # point_type: :name | :args
  #   :name (default) points to the method/variable name where the exception occurred.
  #   :args points to the arguments of the method call where the exception occurred.
  #
  # backtrace_location: Thread::Backtrace::Location
  #   It locates the code fragment of the given backtrace_location.
  #   By default, it uses the first frame of backtrace_locations of the given exception.
  #
  # Returns:
  #  {
  #    first_lineno: Integer,
  #    first_column: Integer,
  #    last_lineno: Integer,
  #    last_column: Integer,
  #    snippet: String,
  #    script_lines: [String],
  #  } | nil
  #
  # Limitations:
  #
  # Currently, ErrorHighlight.spot only supports a single-line code fragment.
  # Therefore, if the return value is not nil, first_lineno and last_lineno will have
  # the same value. If the relevant code fragment spans multiple lines
  # (e.g., Array#[] of <tt>ary[(newline)expr(newline)]</tt>), the method will return nil.
  # This restriction may be removed in the future.
  def self.spot(obj, **opts)
    case obj
    when Exception
      exc = obj
      loc = opts[:backtrace_location]
      opts = { point_type: opts.fetch(:point_type, :name) }
      opts[:name] = exc.name if NameError === exc

      unless loc
        case exc
        when TypeError, ArgumentError
          opts[:point_type] = :args
        end

        locs = exc.backtrace_locations
        return nil unless locs

        loc = locs.find { |l| l.absolute_path && File.exist?(l.absolute_path) } || locs.first
        return nil unless loc
      end

      return nil unless Thread::Backtrace::Location === loc

      callee = ArgumentError === exc &&
               same_backtrace_location?(loc, exc.backtrace_locations&.first) &&
               opts[:point_type] == :name

      Spotter.new(loc, **opts, callee: callee, backtrace_locations: exc.backtrace_locations, message: exc.message).spot

    when Prism::Node
      Spotter.new(obj, **opts).spot

    else
      raise TypeError, "Exception or Prism::Node is expected"
    end

  rescue SyntaxError,
         SystemCallError, # file not found or something
         ArgumentError # eval'ed code

    return nil
  end

  def self.same_backtrace_location?(left, right)
    return false unless left && right
    left.path == right.path &&
      left.lineno == right.lineno &&
      left.label == right.label &&
      left.base_label == right.base_label
  end

  private_class_method :same_backtrace_location?

  class Spotter
    class NonAscii < Exception; end
    private_constant :NonAscii

    def initialize(node_or_location, point_type: :name, name: nil, callee: false, backtrace_locations: nil, message: nil)
      @point_type = point_type
      @name = name
      @message = message

      if node_or_location.is_a?(Thread::Backtrace::Location)
        @node = find_node(node_or_location, callee, backtrace_locations)
      else
        @node = node_or_location
      end

      # Not-implemented-yet options
      @arg = nil # Specify the index or keyword at which argument caused the TypeError/ArgumentError
      @multiline = false # Allow multiline spot

      @fetch = -> (lineno, last_lineno = lineno) do
        return "" unless @node
        snippet = @node.location.source_lines[lineno - 1 .. last_lineno - 1].join("")
        snippet += "\n" unless snippet.end_with?("\n")

        # It requires some work to support Unicode (or multibyte) characters.
        # Tentatively, we stop highlighting if the code snippet has non-ascii characters.
        # See https://github.com/ruby/error_highlight/issues/4
        raise NonAscii unless snippet.ascii_only?

        snippet
      end
    end

    def spot
      return nil unless @node

      # In Ruby 3.2 or later, a nested constant access (like `Foo::Bar::Baz`)
      # is compiled to one instruction (opt_getconstant_path).
      # @node points to the node of the whole `Foo::Bar::Baz` even if `Foo`
      # or `Foo::Bar` causes NameError.
      # So we try to spot the sub-node that causes the NameError by using
      # `NameError#name`.
      case @node.type
      when :constant_path_node
        subnodes = []
        node = @node

        begin
          subnodes << node if node.name == @name
        end while (node = node.parent).is_a?(Prism::ConstantPathNode)

        if node.is_a?(Prism::ConstantReadNode) && node.name == @name
          subnodes << node
        end

        # If we found only one sub-node whose name is equal to @name, use it
        return nil if subnodes.size != 1
        @node = subnodes.first
      end

      case @node.type
      when :call_node
        case @point_type
        when :name
          spot_call_for_name
        when :args
          spot_call_for_args
        end

      when :local_variable_operator_write_node
        case @point_type
        when :name
          spot_write_for_name
        when :args
          spot_write_for_args
        end

      when :instance_variable_operator_write_node,
           :global_variable_operator_write_node,
           :class_variable_operator_write_node
        case @point_type
        when :name
          spot_variable_write_for_name
        when :args
          spot_write_for_args
        end

      when :call_operator_write_node
        case @point_type
        when :name
          spot_call_write_for_name
        when :args
          spot_call_write_for_args
        end

      when :index_operator_write_node
        case @point_type
        when :name
          spot_index_write_for_name
        when :args
          spot_index_write_for_args
        end

      when :constant_read_node
        spot_constant_read

      when :constant_path_node
        spot_constant_path

      when :constant_path_operator_write_node
        case @point_type
        when :name
          spot_constant_path_write
        when :args
          spot_write_for_args
        end

      when :constant_operator_write_node
        case @point_type
        when :name
          spot_constant_write
        when :args
          spot_write_for_args
        end

      when :def_node
        case @point_type
        when :name
          spot_def_for_name
        when :args
          raise NotImplementedError
        end

      when :lambda_node
        case @point_type
        when :name
          spot_lambda_for_name
        when :args
          raise NotImplementedError
        end

      when :block_node
        case @point_type
        when :name
          spot_block_for_name
        when :args
          raise NotImplementedError
        end

      end

      if @snippet && @beg_column && @end_column && @beg_column < @end_column
        return {
          first_lineno: @beg_lineno,
          first_column: @beg_column,
          last_lineno: @end_lineno,
          last_column: @end_column,
          snippet: @snippet,
          script_lines: @node.location.source_lines,
        }
      else
        return nil
      end

    rescue NonAscii
      nil
    end

    private

    def find_node(location, callee, backtrace_locations = nil)
      absolute_path = location.absolute_path
      return nil unless absolute_path
      return nil unless File.exist?(absolute_path)

      result = Prism.parse_file(absolute_path)
      return nil unless result.success?

      candidates = backtrace_candidates(result.value, location.lineno)
      return nil if candidates.empty?

      # Resolve Ruby label if possible to get correct block depth when the first frame is a C method
      label = resolved_backtrace_label(location, backtrace_locations)

      # 1. Filter by block nesting depth and map to plain nodes
      candidates = filter_to_current_block(candidates, label, callee)

      if callee
        candidates = find_definition(candidates, label)
        if candidates.empty?
          # Fallback to call site search (C method called from Ruby caller frame)
          callee = false
          candidates = backtrace_candidates(result.value, location.lineno)
          candidates = filter_to_current_block(candidates, label, false)
        end
      end

      return nil if candidates.empty?

      # 2. Prefer candidates matching the backtrace label name
      matched_label = candidates.select { |node| node_matches_label?(node, label) }
      candidates = matched_label unless matched_label.empty?

      # 3. Filter by NameError name if available
      if @name
        candidates = find_by_name(candidates, @name)
      end

      # 4. Filter by resolved call name from backtrace if available (to disambiguate multi-call lines)
      unless callee
        call_name = resolved_call_name(location, backtrace_locations)
        if call_name
          candidates = find_by_name(candidates, call_name)
        end
      end

      # 5. Filter by call site (if caller frame)
      unless callee
        candidates = find_call_site(candidates)
      end

      candidates = find_by_message(candidates) if @point_type == :args

      unique_best_candidate(candidates)
    end

    def resolved_backtrace_label(location, backtrace_locations)
      return location.label unless backtrace_locations
      return location.label if block_label?(location.label)
      idx = backtrace_locations.find_index do |l|
        l.path == location.path &&
        l.lineno == location.lineno &&
        l.label == location.label &&
        l.base_label == location.base_label
      end
      return location.label unless idx

      subsequent_locs = backtrace_locations[(idx + 1)..-1] || []
      matching_loc = subsequent_locs.find do |l|
        l.path == location.path &&
        l.lineno == location.lineno &&
        l.label != location.label
      end

      matching_loc ? matching_loc.label : location.label
    end

    def resolved_call_name(location, backtrace_locations)
      return nil unless backtrace_locations
      idx = backtrace_locations.find_index { |l| l == location }
      idx ||= backtrace_locations.find_index do |l|
        l.path == location.path &&
        l.lineno == location.lineno &&
        l.label == location.label &&
        l.base_label == location.base_label
      end
      return nil unless idx

      if idx > 0
        callee_loc = backtrace_locations[idx - 1]
        if callee_loc.base_label && !block_label?(callee_loc.label)
          return callee_loc.base_label.to_sym
        end
      else
        if location.base_label && !block_label?(location.label)
          return location.base_label.to_sym
        end
      end
      nil
    end

    def backtrace_candidates(root, lineno)
      collect_candidates(root, lineno)
    end

    def collect_candidates(node, lineno, depth = 0, candidates = [])
      return candidates unless node
      if node.location.start_line <= lineno && lineno <= node.location.end_line
        candidates << [node, depth] if supported_node?(node)

        node.compact_child_nodes.each do |child|
          next if node.is_a?(Prism::ConstantPathOperatorWriteNode) && child == node.target
          next if node.is_a?(Prism::ConstantPathNode) && child == node.parent

          next_depth = depth
          if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
            next_depth += 1
          elsif node.is_a?(Prism::DefNode)
            next_depth = 0
          end
          collect_candidates(child, lineno, next_depth, candidates)
        end
      end
      candidates
    end

    def supported_node?(node)
      case node
      when Prism::CallNode,
           Prism::LocalVariableOperatorWriteNode,
           Prism::InstanceVariableOperatorWriteNode,
           Prism::GlobalVariableOperatorWriteNode,
           Prism::ClassVariableOperatorWriteNode,
           Prism::CallOperatorWriteNode,
           Prism::IndexOperatorWriteNode,
           Prism::ConstantReadNode,
           Prism::ConstantPathNode,
           Prism::ConstantPathOperatorWriteNode,
           Prism::ConstantOperatorWriteNode,
           Prism::DefNode,
           Prism::LambdaNode,
           Prism::BlockNode
        true
      else
        false
      end
    end

    def filter_to_current_block(candidates_with_depth, label, callee)
      target_depth = label_depth(label)

      candidates_with_depth.select do |node, depth|
        if callee
          if target_depth > 0
            depth == target_depth - 1 && (node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode))
          else
            depth == 0 && node.is_a?(Prism::DefNode)
          end
        else
          depth >= target_depth
        end
      end.map { |node, depth| node }
    end

    def label_depth(label)
      return 0 unless label
      if label == "block" || label.start_with?("block in ")
        1
      elsif label =~ /\Ablock \((\d+) levels\) in /
        $1.to_i
      else
        0
      end
    end

    def block_label?(label)
      label_depth(label) > 0
    end

    def node_matches_label?(node, label)
      return false unless label
      method_name = label.split("#").last.split(".").last
      case node
      when Prism::CallNode
        node.name.to_s == method_name
      when Prism::CallOperatorWriteNode
        node.read_name.to_s == method_name || node.write_name.to_s == method_name
      when Prism::IndexOperatorWriteNode
        method_name == "[]" || method_name == "[]="
      else
        false
      end
    end

    def find_by_name(candidates, name)
      matched = candidates.select { |node| node_matches_name?(node, name) }
      matched.empty? ? candidates : matched
    end

    def node_matches_name?(node, name)
      return false unless name
      case node
      when Prism::CallNode
        node.name == name
      when Prism::LocalVariableOperatorWriteNode
        node.name == name
      when Prism::InstanceVariableOperatorWriteNode,
           Prism::GlobalVariableOperatorWriteNode,
           Prism::ClassVariableOperatorWriteNode,
           Prism::ConstantOperatorWriteNode
        node.name == name || node.binary_operator == name
      when Prism::CallOperatorWriteNode
        node.read_name == name || node.write_name == name || node.binary_operator == name
      when Prism::IndexOperatorWriteNode
        name == :[] || name == :[]= || node.binary_operator == name
      when Prism::ConstantReadNode
        node.name == name
      when Prism::ConstantPathNode
        curr = node
        while curr.is_a?(Prism::ConstantPathNode)
          return true if curr.name == name
          curr = curr.parent
        end
        curr.is_a?(Prism::ConstantReadNode) && curr.name == name
      when Prism::ConstantPathOperatorWriteNode
        node.target.name == name || node.binary_operator == name
      when Prism::DefNode
        node.name == name
      else
        false
      end
    end

    def find_definition(candidates, label)
      defs = candidates.select { |node| definition_node?(node) }
      return [] if defs.empty?

      if label
        method_name = label.split("#").last.split(".").last
        if label_depth(label) > 0
          # We are in a block/lambda
          blocks = defs.select { |node| node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode) }
          return blocks
        else
          # We are in a method definition
          methods = defs.select { |node| node.is_a?(Prism::DefNode) && node.name.to_s == method_name }
          return methods
        end
      end

      defs
    end

    def definition_node?(node)
      node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)
    end

    def find_call_site(candidates)
      calls = candidates.select { |node| call_like_node?(node) }
      calls.empty? ? candidates : calls
    end

    def find_by_message(candidates)
      return candidates unless @message&.downcase&.include?("nil")

      matched = candidates.select do |node|
        location = args_location(node)
        location && location.slice.match?(/\bnil\b/)
      end

      matched.empty? ? candidates : matched
    end

    def args_location(node)
      case node
      when Prism::CallNode
        node.arguments&.location
      when Prism::LocalVariableOperatorWriteNode,
           Prism::InstanceVariableOperatorWriteNode,
           Prism::GlobalVariableOperatorWriteNode,
           Prism::ClassVariableOperatorWriteNode,
           Prism::ConstantOperatorWriteNode,
           Prism::CallOperatorWriteNode,
           Prism::IndexOperatorWriteNode,
           Prism::ConstantPathOperatorWriteNode
        node.value.location
      end
    end

    def call_like_node?(node)
      node.is_a?(Prism::CallNode) ||
        node.is_a?(Prism::CallOperatorWriteNode) ||
        node.is_a?(Prism::IndexOperatorWriteNode)
    end

    def unique_best_candidate(candidates)
      return nil if candidates.empty?
      return candidates.first if candidates.size == 1

      slices = candidates.map { |node| node.location.slice }.uniq
      slices.size == 1 ? candidates.first : nil
    end

    def fetch_line(lineno)
      @beg_lineno = @end_lineno = lineno
      @snippet = @fetch[lineno]
    end

    # Take a location from the prism parser and set the necessary instance
    # variables.
    def prism_location(location)
      @beg_lineno = location.start_line
      @beg_column = location.start_column
      @end_lineno = location.end_line
      @end_column = location.end_column
      @snippet = @fetch[@beg_lineno, @end_lineno]
    end

    # Example:
    #   x.foo
    #    ^^^^
    #   x.foo(42)
    #    ^^^^
    #   x&.foo
    #    ^^^^^
    #   x[42]
    #    ^^^^
    #   x.foo = 1
    #    ^^^^^^
    #   x[42] = 1
    #    ^^^^^^
    #   x + 1
    #     ^
    #   +x
    #   ^
    #   foo(42)
    #   ^^^
    #   foo 42
    #   ^^^
    #   foo
    #   ^^^
    def spot_call_for_name
      # Explicitly turn off foo.() syntax because error_highlight expects this
      # to not work.
      return nil if @node.name == :call && @node.message_loc.nil?

      location = @node.message_loc || @node.call_operator_loc || @node.location
      location = @node.call_operator_loc.join(location) if @node.call_operator_loc&.start_line == location.start_line

      # If the method name ends with "=" but the message does not, then this is
      # a method call using the "attribute assignment" syntax
      # (e.g., foo.bar = 1). In this case we need to go retrieve the = sign and
      # add it to the location.
      if (name = @node.name).end_with?("=") && !@node.message.end_with?("=")
        location = location.adjoin("=")
      end

      prism_location(location)

      if !name.end_with?("=") && !name.match?(/[[:alpha:]_\[]/)
        # If the method name is an operator, then error_highlight only
        # highlights the first line.
        fetch_line(location.start_line)
      end
    end

    # Example:
    #   x.foo(42)
    #         ^^
    #   x[42]
    #     ^^
    #   x.foo = 1
    #           ^
    #   x[42] = 1
    #     ^^^^^^^
    #   x[] = 1
    #     ^^^^^
    #   x + 1
    #       ^
    #   foo(42)
    #       ^^
    #   foo 42
    #       ^^
    def spot_call_for_args
      # Disallow highlighting arguments if there are no arguments.
      return if @node.arguments.nil?

      # Explicitly turn off foo.() syntax because error_highlight expects this
      # to not work.
      return nil if @node.name == :call && @node.message_loc.nil?

      if @node.name == :[]= && @node.opening == "[" && (@node.arguments&.arguments || []).length == 1
        prism_location(@node.opening_loc.copy(start_offset: @node.opening_loc.start_offset + 1).join(@node.arguments.location))
      else
        prism_location(@node.arguments.location)
      end
    end

    # Example:
    #   x += 1
    #     ^
    def spot_write_for_name
      prism_location(@node.binary_operator_loc.chop)
    end

    # Example:
    #   x += 1
    #        ^
    def spot_write_for_args
      prism_location(@node.value.location)
    end

    # Example:
    #   @x += 1
    #      ^
    #   @@x += 1
    #   ^^^
    def spot_variable_write_for_name
      if @name == @node.name
        prism_location(@node.name_loc)
      else
        spot_write_for_name
      end
    end

    # Example:
    #   x.foo += 42
    #    ^^^     (for foo)
    #   x.foo += 42
    #         ^  (for +)
    #   x.foo += 42
    #    ^^^^^^^ (for foo=)
    def spot_call_write_for_name
      if !@name.start_with?(/[[:alpha:]_]/)
        prism_location(@node.binary_operator_loc.chop)
      else
        location = @node.message_loc
        if @node.call_operator_loc.start_line == location.start_line
          location = @node.call_operator_loc.join(location)
        end

        location = location.adjoin("=") if @name.end_with?("=")
        prism_location(location)
      end
    end

    # Example:
    #   x.foo += 42
    #            ^^
    def spot_call_write_for_args
      prism_location(@node.value.location)
    end

    # Example:
    #   x[1] += 42
    #    ^^^    (for [])
    #   x[1] += 42
    #        ^  (for +)
    #   x[1] += 42
    #    ^^^^^^ (for []=)
    def spot_index_write_for_name
      case @name
      when :[]
        prism_location(@node.opening_loc.join(@node.closing_loc))
      when :[]=
        prism_location(@node.opening_loc.join(@node.closing_loc).adjoin("="))
      else
        # Explicitly turn off foo[] += 1 syntax when the operator is not on
        # the same line because error_highlight expects this to not work.
        return nil if @node.binary_operator_loc.start_line != @node.opening_loc.start_line

        prism_location(@node.binary_operator_loc.chop)
      end
    end

    # Example:
    #   x[1] += 42
    #     ^^^^^^^^
    def spot_index_write_for_args
      opening_loc =
        if @node.arguments.nil?
          @node.opening_loc.copy(start_offset: @node.opening_loc.start_offset + 1)
        else
          @node.arguments.location
        end

      prism_location(opening_loc.join(@node.value.location))
    end

    # Example:
    #   Foo
    #   ^^^
    def spot_constant_read
      prism_location(@node.location)
    end

    # Example:
    #   Foo::Bar
    #      ^^^^^
    def spot_constant_path
      if @node.parent && @node.parent.location.end_line == @node.location.end_line
        fetch_line(@node.parent.location.end_line)
        prism_location(@node.delimiter_loc.join(@node.name_loc))
      else
        fetch_line(@node.location.end_line)
        location = @node.name_loc
        location = @node.delimiter_loc.join(location) if @node.delimiter_loc.end_line == location.start_line
        prism_location(location)
      end
    end

    # Example:
    #   Foo::Bar += 1
    #      ^^^^^^^^
    def spot_constant_path_write
      if @name == (target = @node.target).name
        prism_location(target.delimiter_loc.join(target.name_loc))
      else
        prism_location(@node.binary_operator_loc.chop)
      end
    end

    # Example:
    #   Foo += 1
    #   ^^^
    #   Foo += 1
    #       ^
    def spot_constant_write
      if @name == @node.name
        prism_location(@node.name_loc)
      else
        spot_write_for_name
      end
    end

    # Example:
    #   def foo()
    #       ^^^
    def spot_def_for_name
      location = @node.name_loc
      location = @node.operator_loc.join(location) if @node.operator_loc
      prism_location(location)
    end

    # Example:
    #   -> x, y { }
    #   ^^
    def spot_lambda_for_name
      prism_location(@node.operator_loc)
    end

    # Example:
    #   lambda { }
    #          ^
    #   define_method :foo do |x, y|
    #                      ^
    def spot_block_for_name
      prism_location(@node.opening_loc)
    end
  end

  private_constant :Spotter
end
