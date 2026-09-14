# Ruby LSP Slim

A [Ruby LSP](https://github.com/Shopify/ruby-lsp) addon that provides language server features for [Slim](http://slim-lang.com/) template files.

## Features

- **Hover** — see method signatures and documentation
- **Go-to-definition** — jump to method/class definitions from Slim templates
- **Completion** — autocomplete Ruby methods and variables
- **Document symbols** — outline view for Ruby code in templates
- **Diagnostics** — Slim and embedded Ruby syntax errors
- **Semantic highlighting** — rich syntax coloring for embedded Ruby
- **Document highlights** — highlight matching Ruby symbols in a template
- **Folding** — collapse original Slim tags, Ruby blocks, and embedded filter containers
- **References and constant rename** — mapped Ruby references and safe constant edits across templates

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

The extension runs a dedicated Ruby LSP server for `.slim` files. The supported features and current limitations are described below.

### 3. Restart VS Code

After installing both the gem and extension, reload your VS Code window (`Cmd+Shift+P` → "Developer: Reload Window").


## Supported Slim syntax

| Pattern | Example |
|---|---|
| Control code | `- x = 1` |
| Output | `= link_to "Home", root_path` |
| Unescaped output | `== raw_html` |
| Tag output | `h1= title` or `h1 = title` |
| Interpolation | `p Hello #{user.name}` |
| Ruby filter | `ruby:` block |
| Comments | `/ comment` |
| Text blocks | `\| text content` |
| Backslash continuation | `- x = 1 + \` (continues next line) |

Indentation closes Ruby blocks such as `if`/`else` and `each do`; explicit Slim `- end` statements are rejected, as they are by Slim itself. Syntax availability follows the installed Slim version.

## Parsing and source locations

The add-on uses Slim's parser and structural passes to produce Ruby-only source. A source map connects copied Ruby expressions to the original template and identifies synthetic code such as block endings. Ruby LSP analyzes the generated document; request positions, response ranges, and edits are translated at the boundary. The original template remains the editable document.

Edits require an exact mapping. An operation that would change synthetic code or cross omitted template text is rejected rather than approximated.

Folding ranges come directly from the original Slim structure. They cover multiline nested tags, indentation-delimited Ruby control and output blocks, and every embedded filter container recognized by the installed Slim parser. Filter bodies are opaque: their internal indentation does not create nested Slim folds, and trailing blank lines are excluded. Standalone comments, verbatim text, inline HTML, and attribute/header-only continuations do not create independent folds.

Folding is best effort while editing. Embedded Ruby errors do not remove folds whose Slim structure is still known. If Slim itself reports a syntax error, only regions closed before the error are retained; open or uncertain regions are omitted rather than extended across malformed input.

### Current limitations

- Incomplete or invalid templates receive current syntax diagnostics. Projection-dependent semantic features are temporarily unavailable until the template parses again; an older AST is never reused. This includes completion after an incomplete expression such as `user.`. Folding can remain available when Slim structure was established despite embedded Ruby errors.
- Diagnostics do not run Ruby linters or publish Prism warnings from generated code.
- Reference search includes managed Slim documents, not every unopened template. Constant rename additionally checks workspace `.slim` files and fails without returning partial edits if a participating template is invalid, its scope is ambiguous, or an edit cannot be mapped safely. Rename retains Ruby LSP's indexed-constant scope; method and local-variable rename are not added.
- External symbol definitions currently require UTF-16 position negotiation because of coordinate behavior in Ruby LSP's index. File-start links such as `require_relative` work with UTF-8, UTF-16, and UTF-32.
- Slim formatting, code actions, selection ranges, document links, code lenses, inlay hints, signature help, and type hierarchy are not yet adapted. These requests fail explicitly instead of returning generated-source coordinates. A shared server may still advertise them for Ruby files.
- Ruby projection for foreign embedded engines and arbitrary third-party add-on coordinate conventions is not supported. Their parser-recognized containers can still fold opaquely. The parser integration uses internal Slim hooks; compatibility tests cover the supported parser versions.

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
