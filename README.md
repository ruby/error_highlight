# ErrorHighlight

## Installation

Ruby 3.1 will ship with this gem and it will automatically be `require`d when a Ruby process starts up. No special setup is required.

Note: This gem works only on MRI and requires Ruby 3.1 or later because it depends on MRI's internal APIs that are available since 3.1.

## Examples

```ruby
1.time {}
```

```
$ ruby test.rb
test.rb:1:in `<main>': undefined method `time' for 1:Integer (NoMethodError)

1.time {}
 ^^^^^
Did you mean?  times
```

## More example

```ruby
def extract_value(data)
  data[:results].first[:value]
end
```

When `data` is `{ :results => [] }`, the following error message is shown:

```
$ ruby test.rb
test.rb:2:in `extract_value': undefined method `[]' for nil:NilClass (NoMethodError)

  data[:results].first[:value]
                      ^^^^^^^^
        from test.rb:5:in `<main>'
```

When `data` is `nil`, it prints:

```
$ ruby test.rb
test.rb:2:in `extract_value': undefined method `[]' for nil:NilClass (NoMethodError)

  data[:results].first[:value]
      ^^^^^^^^^^
        from test.rb:5:in `<main>'
```

## Using the `ErrorHighlight.spot`

*Note: This API is experimental, may change in future.*

You can use the `ErrorHighlight.spot` method to get the snippet data.
Note that the argument must be a RubyVM::AbstractSyntaxTree::Node object that is created with `keep_script_lines: true` option (which is available since Ruby 3.1).

```ruby
class Dummy
  def test(_dummy_arg)
    node = RubyVM::AbstractSyntaxTree.of(caller_locations.first, keep_script_lines: true)
    ErrorHighlight.spot(node)
  end
end

pp Dummy.new.test(42) # <- Line 8
#           ^^^^^       <- Column 12--17

#=> {:first_lineno=>8,
#    :first_column=>12,
#    :last_lineno=>8,
#    :last_column=>17,
#    :snippet=>"pp Dummy.new.test(42) # <- Line 8\n"}
```

## Custom Formatter

If you want to customize the message format for code snippet, use `ErrorHighlight.formatter=` to set your custom object that responds to `message_for` method.

```ruby
formatter = Object.new
def formatter.message_for(spot)
  marker = " " * spot[:first_column] + "^" + "~" * (spot[:last_column] - spot[:first_column] - 1)

  "\n\n#{ spot[:snippet] }#{ marker }"
end

ErrorHighlight.formatter = formatter

1.time {}

#=>
#
# test.rb:10:in `<main>': undefined method `time' for 1:Integer (NoMethodError)
#
# 1.time {}
#  ^~~~~
# Did you mean?  times
```

## Disabling `error_highlight`

Occasionally, you may want to disable the `error_highlight` gem for e.g. debugging issues in the error object itself. You
can disable it entirely by specifying `--disable-error_highlight` option to the `ruby` command:

```bash
$ ruby --disable-error_highlight -e '1.time {}'
-e:1:in `<main>': undefined method `time' for 1:Integer (NoMethodError)
Did you mean?  times
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ruby/error_highlight.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
