# HeexLint

An agent-first linter for Tailwind classes in Phoenix HEEx templates.

You define what your design system allows. When code breaks a rule, the error
says what's wrong and what to use instead, drawn from your own theme:

```text
lib/my_app_web/components/core_components.ex:536:66 error "text-zinc-600" is a raw Tailwind
palette color, so it ignores the theme and its dark mode. Use the closest theme color:
text-(--muted) (#5f5f5f), ... Theme colors are in assets/css/app.css. [no_raw_colors]
```

Inspired by [`@shadcn/lint`](https://github.com/shadcn-ui/lint), which does the
same for React, Vue and Svelte.

## Installation

```elixir
def deps do
  [
    {:heex_lint, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Run it, and add it to your `precommit` alias so agents check their own work:

```sh
mix heex_lint
```

```elixir
precommit: ["compile --warnings-as-errors", "format", "heex_lint", "test"]
```

## What it reads

- `~H` sigils in `.ex`/`.exs` files and `.heex` templates, with exact file, line and column.
- `class` attributes (and `*_class` attributes) on HTML tags, components and slots.
- Class expressions as Elixir code: list items, `@flag && "..."`, `if`/`case`/`cond`
  branches, `~w(...)`, interpolation and `<>`. Conditions are skipped, so
  `if(@size == "sm", do: "p-2")` only yields `p-2`.
- Your theme: CSS custom properties in `assets/css/app.css` and its local `@import`s.
  `@theme` colors become utilities (`bg-brand`); other color variables are suggested
  through the shorthand (`bg-(--surface)`).

## Rules

| Rule | What it catches |
| --- | --- |
| `no_raw_colors` | Default palette colors like `bg-zinc-100` or `text-white`. Suggests the theme colors that look closest, preferring those the project already uses with the same utility. |
| `no_arbitrary_values` | Arbitrary values like `p-[13px]`, `text-[11px]`, `bg-[#fff]`. Suggests the exact spacing step, the nearest font size or radius, or the closest theme color. Variable references like `bg-(--surface)` are allowed. |
| `no_inline_styles` | `style` attributes and `<style>` elements. Setting CSS variables (`style="--progress: 40%"`) is allowed. |
| `require_static_classes` | Classes built at runtime, like `"bg-#{@color}"`, which Tailwind can't see. Plain CSS classes from your stylesheet (`"toast--#{@kind}"`) are allowed. |
| `no_unknown_variables` | Classes reading a CSS variable the theme doesn't define, like `bg-(--surfce)`. Suggests close names. |

## Configuration

Everything is optional. Create `.heex_lint.exs` in the project root:

```elixir
[
  inputs: ["lib/**/*.{ex,heex}"],
  theme: "assets/css/app.css",
  class_attributes: ["class", ~r/_class$/],
  # Appended to every message.
  note: "See DESIGN.md for the design rules.",
  rules: [
    no_raw_colors: :error,
    no_arbitrary_values: {:error, allow: ["grid-cols-[*"]},
    no_inline_styles: {:warning, allow: ["view-transition-name"]},
    require_static_classes: :error,
    no_unknown_variables: {:error, allow: ["--radix-*"]}
  ]
]
```

A rule is `:error`, `:warning`, `:off` or `{severity, options}`. Every rule
takes `:allow` patterns (`*` matches anything, or use a regex) and a custom
`:message` with placeholders such as `{{class}}` and `{{suggestion}}`. See each
rule's docs for its options.

Custom rules are modules implementing `HeexLint.Rule`, listed by module name
under `rules`.

## Command line

```sh
mix heex_lint                          # lint the configured inputs
mix heex_lint lib/my_app_web/components
mix heex_lint --format json            # for editors and agents
mix heex_lint --max-warnings 0
```

The task exits with status 1 on errors, unparsable templates, or more warnings
than `--max-warnings`.

## Acknowledgements

The HEEx tokenizer is vendored from [Phoenix LiveView](https://github.com/phoenixframework/phoenix_live_view)
(MIT), so HeexLint has no runtime dependencies and doesn't break when LiveView
moves its private modules. The default color palette comes from
[Tailwind CSS](https://github.com/tailwindlabs/tailwindcss) (MIT).

## License

MIT
