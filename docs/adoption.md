# Adding linting to an existing project

Start with one rule. Fix the common violations, then add more checks.

## Start with warnings

```elixir
# .heex_lint.exs
[
  rules: [no_restyle: {:warning, allow: ["layout"]}],
  overrides: [[files: ["lib/my_app_web/components/**"], rules: [no_restyle: :off]]]
]
```

```sh
mix heex_lint
```

Look for repeated findings, such as padding on buttons, and fix those
patterns before working through individual files.

## Limit the warning count

Use the measured count in CI. If the project has 287 warnings:

```sh
mix heex_lint --max-warnings 287
```

It fails when the total increases. Lower the cap as you fix findings.

## Keep new code strict

Overrides apply in order, so new code can be strict while legacy code warns:

```elixir
rules: [no_restyle: {:error, allow: ["layout"]}],
overrides: [
  [files: ["lib/my_app_web/legacy/**"], rules: [no_restyle: :warning]],
  [files: ["lib/my_app_web/marketing/**"], rules: [no_restyle: :off]]
]
```

An override that sets only a severity keeps the rule's options.

## Fix findings

- Use an existing variant for a component's appearance.
- Use a contract when callers should control part of its styling.
- Use suggested tokens or scale values when they match the design;
  `mix heex_lint --fix` applies the unambiguous ones.
- Review new tokens and variants before adding them.

A title can allow typography through a contract:

```elixir
no_restyle: {:warning, allow: ["layout"], contracts: [
  [pattern: "^card_title$", allow: ["layout", "typography"]]
]}
```

A contract overrides the keys it writes and inherits the rest, so one that
writes `allow` restates `layout` when the component should keep it.

## Add more rules

When a rule is clean, make it an error. Add others at `:warning` first. All
rules, as the recommended config enables them:

```elixir
rules: [
  no_restyle: {:error, allow: ["layout"]},
  no_raw_colors: :error,
  no_arbitrary_values: {:error, allow: ["layout"]},
  no_inline_styles: :error,
  require_static_classes: :error,
  no_unknown_classes: :warning,
  no_unknown_variables: :error
],
overrides: [
  [
    files: ["lib/my_app_web/components/**"],
    rules: [no_restyle: :off, no_arbitrary_values: :off, require_static_classes: :off]
  ]
]
```

Components own their appearance and may need structural values, so those
three rules are off in the component directory; `no_raw_colors` and
`no_inline_styles` stay on there. Classes supplied by stylesheets outside
your theme may need `no_unknown_classes` `allow` entries.

## Agents

Add `heex_lint` to your `precommit` alias, then put this in `AGENTS.md`:

```md
After making changes, run `mix precommit` and fix all errors.
```

Review new tokens, variants and exceptions in the resulting changes.

## Exceptions

Document an intentional exception next to the code:

```heex
<%!-- heex-lint-disable-next-line no_raw_colors -- Partner brand color, approved by design. --%>
<span class="bg-amber-400">Sponsor</span>
```

`grep -rn "heex-lint-disable"` finds these comments.
