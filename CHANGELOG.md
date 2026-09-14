# Changelog

## Unreleased

- Add conservative original-template folding for nested Slim tags, Ruby control and output blocks, and all parser-recognized filter containers.
- Replace the handwritten scanner with Slim-backed Ruby projection and source mapping, fixing spaced tag output and indentation-based Ruby blocks.
- Preserve template source locations through Ruby LSP requests, including Unicode and multiline Ruby normalization.
- Report current syntax errors without crashing or reusing stale document state during edits.
- Add mapped cross-document references and constant rename, rejecting unsafe or incomplete workspace edits.
- Remove the internal `RubyLsp::RubyLspSlim::SlimScanner` class; direct users of that implementation must migrate.
- Limit the dedicated VS Code client's enabled features to mapped operations, avoiding repeated unsupported-feature requests.
- Document source mapping and unsupported template operations.

## 0.1.0

- Initial release
- Support for hover, go-to-definition, completion, document symbols, diagnostics, and semantic highlighting in Slim templates
- Handles control code (`-`), output (`=`, `==`), interpolation (`#{}`), ruby filter, comments, text blocks, and backslash continuation
