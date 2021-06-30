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

When `data` is `{ :results => [] }`, the following error messsage is shown:

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
