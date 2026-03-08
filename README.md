# Ruby LSP Slim

A [Ruby LSP](https://github.com/Shopify/ruby-lsp) addon that provides language server features for [Slim](http://slim-lang.com/) template files.

## Features

- **Hover** — see method signatures and documentation
- **Go-to-definition** — jump to method/class definitions from Slim templates
- **Completion** — autocomplete Ruby methods and variables
- **Document symbols** — outline view for Ruby code in templates
- **Diagnostics** — syntax errors and warnings
- **Semantic highlighting** — rich syntax coloring for embedded Ruby

## Installation

### 1. Add the gem

Add `ruby-lsp-slim` to your project's `Gemfile`:

```ruby
group :development do
  gem "ruby-lsp-slim"
end
```

Then run `bundle install`.

### 2. Install the VS Code extension

Install the **Ruby LSP Slim** extension from the VS Code marketplace, or search for "Ruby LSP Slim" in the Extensions panel.

The extension runs a dedicated Ruby LSP server for `.slim` files, so all standard Ruby LSP features work inside your templates.

### 3. Restart VS Code

After installing both the gem and extension, reload your VS Code window (`Cmd+Shift+P` → "Developer: Reload Window").

## Supported Slim syntax

| Pattern | Example |
|---|---|
| Control code | `- x = 1` |
| Output | `= link_to "Home", root_path` |
| Unescaped output | `== raw_html` |
| Tag output | `h1= title` |
| Interpolation | `p Hello #{user.name}` |
| Ruby filter | `ruby:` block |
| Comments | `/ comment` |
| Text blocks | `\| text content` |
| Backslash continuation | `- x = 1 + \` (continues next line) |

## Requirements

- Ruby >= 3.0.0
- ruby-lsp >= 0.26.0, < 1.0
- slim >= 4.0

## Development

```bash
bundle install
bundle exec rake test
```

## License

MIT
