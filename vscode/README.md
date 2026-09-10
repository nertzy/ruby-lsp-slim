# Ruby LSP Slim

Slim template support for [Ruby LSP](https://github.com/Shopify/ruby-lsp) — hover, go-to-definition, completion, and more for Ruby code in `.slim` files.

## Setup

1. Add the gem to your project:

```ruby
group :development do
  gem "ruby-lsp-slim"
end
```

2. Run `bundle install`
3. Reload your VS Code window

## Features

- **Hover** — see method signatures and documentation
- **Go-to-definition** — jump to method/class definitions
- **Completion** — autocomplete Ruby methods and variables
- **Document symbols** — outline view for Ruby code
- **Diagnostics** — Slim and embedded Ruby syntax errors
- **Semantic highlighting** — rich syntax coloring for embedded Ruby

### Current limitations

This dedicated client does not offer Slim formatting (including range and on-type formatting), folding, selection ranges, document links, signature help, type hierarchy, code actions, code lenses, or inlay hints. These features require Slim-aware source mapping before they can be enabled safely. Other Ruby LSP clients retain their own feature configuration.

## How it works

This extension runs a dedicated Ruby LSP server for `.slim` files. The `ruby-lsp-slim` gem is loaded as an addon that teaches the server how to parse Slim syntax and extract Ruby code for analysis.

## Requirements

- [Ruby LSP](https://github.com/Shopify/ruby-lsp) installed in your project
- `ruby-lsp-slim` gem in your Gemfile
- Ruby >= 3.0.0

## License

MIT
