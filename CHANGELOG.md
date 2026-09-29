# Changelog

## Unreleased

- `mix heex_lint --fix` applies only suggestions that generate the same CSS
  (spacing and radius steps, the variable shorthand). Nearest colors, font
  size steps (which add a line height) and spelling corrections stay
  suggestions; JSON output marks each with `exact`.

## 0.2.0

Rule parity with [@shadcn/lint](https://github.com/shadcn-ui/lint) 0.2.0.

- New rules: `no_restyle` (component contracts, variant and size suggestions,
  wrappers) and `no_unknown_classes` (asks the project's Tailwind v4 through
  Node or the standalone binary, with spelling suggestions).
- `require_static_classes` now checks design-system components only, and
  reports every unreadable part: socket assigns, unknown calls, glued
  interpolation.
- `no_raw_colors` reads `@theme` tokens (with resets and scoped namespaces),
  reports undeclared tokens with spelling corrections, and checks SVG color
  attributes.
- `no_arbitrary_values` names exact scale steps with the project's `--spacing`,
  the nearest font sizes and radii, and the nearest theme colors.
- `no_inline_styles` checks custom properties for hardcoded colors and reports
  unreadable style values; forwarding a received `style` is allowed.
- The shared policy engine: `allow`, `deny`, `contracts`, categories, class
  groups, patterns, and configuration errors for entries that match nothing.
- Custom messages with `{{placeholder|fallback}}`, and a shared `note`.
- The cn 0.3.2 class grammar, verified against the reference implementation.
- Components resolve through `import`, `alias` and `use MyAppWeb, :html`;
  `.heex` files through `embed_templates` and LiveView colocation.
- Configuration: explicit `rules` with a recommended default, file
  `overrides`, shared `settings`.
- Suggestions in JSON output, `mix heex_lint --fix`, `--format github`
  annotations, and `heex-lint-disable` comments.
- Umbrella apps: each app's files are checked against its own theme and
  Tailwind.
- Readable maps spread onto elements and colocated CSS are read.
- `no_arbitrary_values` suggests the variable shorthand for `[var(--x)]`.
- `SETUP.md`: a prompt for coding agents to set the linter up.
- Components you don't own: modules imported from `deps/` resolve, and join
  the design system through `component_imports`.
- Settings of the wrong type warn and are ignored.

## 0.1.0

- First release: `no_raw_colors`, `no_arbitrary_values`, `no_inline_styles`,
  `require_static_classes` and `no_unknown_variables`.
