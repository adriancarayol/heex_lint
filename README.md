# HeexLint

**Write design system rules that agents can verify, for Phoenix.**

HeexLint is an agent-first linter for Tailwind classes in HEEx templates, with
rule parity with [`@shadcn/lint`](https://github.com/shadcn-ui/lint).

You define what's allowed. When code breaks a rule, the error explains what's
wrong and suggests a fix based on your components, variants and theme:

```text
lib/my_app_web/live/settings_live.ex:42:23 error "p-4" is not allowed on <.button>:
<.button> owns its spacing. Use a size (sm, lg), or margin here or gap on the parent
for space around it. Add a size in lib/my_app_web/components/core_components.ex only if
the design explicitly calls for one. [no_restyle]
```

Works with any Tailwind v4 project. It reads your function components, their
`attr` declarations, and your theme's `@theme` tokens. No rewrite required.

## Quickstart

Give your coding agent this prompt:

```text
Read https://github.com/adriancarayol/heex_lint/blob/main/SETUP.md
and set up heex_lint in this project.
```

Or add it to your dev and test dependencies yourself:

```elixir
def deps do
  [
    {:heex_lint, github: "adriancarayol/heex_lint", only: [:dev, :test], runtime: false}
  ]
end
```

Run it:

```sh
mix heex_lint
```

With no configuration, the [recommended rules](#configuration) run. Add it to
your `precommit` alias, and tell your agents in `AGENTS.md`:

```elixir
precommit: ["compile --warnings-as-errors", "format", "heex_lint", "test"]
```

```md
After making changes, run `mix precommit` and fix all errors.
```

## Rules

| Rule                                                     | What it catches                                                   |
| -------------------------------------------------------- | ----------------------------------------------------------------- |
| [`no_restyle`](lib/heex_lint/rules/no_restyle.ex)             | Restyling a design-system component with `class`.               |
| [`no_raw_colors`](lib/heex_lint/rules/no_raw_colors.ex)       | Raw palette colors, undeclared tokens, and raw SVG colors.      |
| [`no_arbitrary_values`](lib/heex_lint/rules/no_arbitrary_values.ex) | Arbitrary values such as `p-[13px]`.                      |
| [`no_inline_styles`](lib/heex_lint/rules/no_inline_styles.ex) | Inline styles and `<style>` elements.                           |
| [`no_unknown_classes`](lib/heex_lint/rules/no_unknown_classes.ex) | Classes your Tailwind cannot generate, such as `rounded-huge`. |
| [`require_static_classes`](lib/heex_lint/rules/require_static_classes.ex) | Component classes the linter cannot read, such as `"bg-#{@color}"`. |
| [`no_unknown_variables`](lib/heex_lint/rules/no_unknown_variables.ex) | Classes reading CSS variables the theme never defines. *HeexLint addition.* |

Each rule's module documents its examples and options. The shared options,
class categories and placeholders are in [docs/rules.md](docs/rules.md).

## You decide what can change

A `Button` that allows margin and width, but controls its own padding:

```elixir
no_restyle: {:error, allow: ["layout"], contracts: [
  [pattern: "^button$", allow: ["w-full", "mt-*", "mb-*"]]
]}
```

```heex
<%!-- Allowed: a size, and the page controls placement and full width. --%>
<.button size="lg" class="mt-4 md:w-full">Save</.button>

<%!-- Error: padding and shape belong to the button. --%>
<.button class="p-4 hover:rounded-full">Save</.button>
```

Give each part of a component its own rules. Let card titles change
typography, but keep their font family and weight; let card content change
spacing, but keep its typography:

```elixir
no_restyle: {:error, allow: ["layout"], contracts: [
  [pattern: "^card_title$", allow: ["layout", "typography"], deny: ["font-*"]],
  [pattern: "^card_content$", allow: ["layout", "spacing"]]
]}
```

Opening up spacing doesn't have to mean allowing arbitrary values. Combine
rules: `no_arbitrary_values` still keeps `p-[13px]` off the scale.

## How it reads your project

- **Components.** A design-system component is a function component in one of
  your component modules: by default, modules under a `components/` directory,
  where Phoenix puts `CoreComponents`, plus the modules `ui` and
  `component_imports` add. `<.button>` resolves through the module's imports,
  including what `use MyAppWeb, :html` brings in, and `<Layouts.app>` through
  its aliases.
- **Components you don't own.** Modules imported from `deps/` (SaladUI,
  PetalComponents, Doggo...) are read too, so their components resolve with
  their attrs. They join the design system when `ui` or `component_imports`
  names them: `component_imports: ["^SaladUI\\."]`.
- **Variants.** `attr :variant, values: ~w(primary ghost)` gives the variants a
  finding suggests; `attr :size, values: ...` the sizes a spacing finding offers.
- **Wrappers.** A component that forwards its `class` (`class={["w-full", @class]}`)
  or its global attributes (`{@rest}` with `attr :rest, :global`) to a
  design-system component gets that component's contract and suggestions.
- **Theme.** The stylesheet that imports Tailwind, found under the project (or
  `theme`). Colors are the `--color-*` tokens in `@theme` (and a utility's own
  namespace, such as `--background-color-*`); scales come from `--spacing`,
  `--text-*` and `--radius-*`, over Tailwind's defaults.
- **Values.** Strings, lists, `if`/`case`/`cond`, `&&`/`||`, `~w(...)`,
  interpolation and `<>`. `@name` follows `assign(assigns, :name, ...)` in the
  rendering function; a function component's received `class` is its own
  input, allowed as-is, with its authored default checked. One hop further
  into body variables, module attributes, same-module helpers such as
  `defp button_variant("primary"), do: "..."`, map lookups, and merge
  functions (`cn`, `Tails.classes`, `TwMerge.merge`...).
- **Tailwind.** `no_unknown_classes` asks your installed Tailwind v4: through
  Node when `tailwindcss` is in `node_modules`, or through the standalone
  `tailwind` binary Phoenix installs in `_build/`. Without either it falls
  back to the class grammar.

See [docs/how-it-works.md](docs/how-it-works.md) for details and limits.

## Documentation

- [Rules](docs/rules.md): shared options, contracts, placeholders and categories.
- [Configuring your design system](docs/design-systems.md): variants, contracts, messages, shared policies.
- [How it works](docs/how-it-works.md): components, themes, values, and what it cannot see.
- [Adding linting to an existing project](docs/adoption.md).
- [Troubleshooting](docs/troubleshooting.md).
- [API reference](docs/api.md).
- [Parity with @shadcn/lint](docs/parity.md).

## Configuration

Create `.heex_lint.exs` in your project root. Every key is optional; without
`rules`, this recommended set applies:

```elixir
[
  inputs: ["lib/**/*.{ex,exs,heex}"],
  settings: [
    # theme: "assets/css/app.css",
    # ui: "MyAppWeb.CoreComponents",
    # note: "See DESIGN.md for design rules and approved exceptions."
  ],
  rules: [
    no_restyle: {:error, allow: ["layout"]},
    no_raw_colors: :error,
    no_arbitrary_values: {:error, allow: ["layout"]},
    no_inline_styles: :error,
    require_static_classes: :error,
    no_unknown_classes: :warning,
    no_unknown_variables: :error
  ],
  # Components own their appearance.
  overrides: [
    [
      files: ["**/components/**"],
      rules: [no_restyle: :off, no_arbitrary_values: :off, require_static_classes: :off]
    ]
  ]
]
```

A rule is `:error`, `:warning`, `:off` or `{severity, options}`. Overrides
apply to matching files in order; one that sets only a severity keeps the
options set before it.

### Settings

| Setting             | What it does                                                               |
| ------------------- | -------------------------------------------------------------------------- |
| `theme`             | The Tailwind stylesheet. Discovered when not set.                          |
| `ui`                | Module prefixes added to the design system: `"MyAppWeb.UI"` matches it and `MyAppWeb.UI.*`. |
| `component_imports` | Regexes on module names that are also the design system.                   |
| `ignore_imports`    | Regexes on module names that never are. Takes precedence.                  |
| `merge_functions`   | Functions whose arguments contain classes, such as `"classes"`.            |
| `variant_functions` | Functions whose map values contain classes.                                |
| `note`              | Appended to every rule's message.                                          |
| `tailwind_bin`      | The standalone Tailwind binary, when it is not in `_build/`.               |

A rule's own `ui`, `component_imports`, `ignore_imports`, `merge_functions`
or `variant_functions` option wins over the shared setting.

### Your own words

Every rule accepts `message`, with placeholders from the finding:

```elixir
no_raw_colors: {:error, message: ~s(Use a theme color for "{{className}}". See {{file}}.)}
```

`no_restyle` also takes one message per category, and contracts can bring
their own:

```elixir
no_restyle: {:error, allow: ["layout"], message: %{
  spacing: "Use a {{component}} size: {{sizes|none defined}}.",
  default: "Use a {{component}} variant: {{variants|none defined}}."
}}
```

See [placeholders](docs/rules.md#your-own-words).

## Suggestions and fixes

Findings carry suggestions: the nearest theme tokens, an exact scale step
(`p-[13px]` → `p-3.25`), the variable shorthand (`bg-[var(--x)]` →
`bg-(--x)`), or a spelling correction. `--format json` includes them, with
`exact: true` on the ones that generate the same CSS. `mix heex_lint --fix`
applies only those, rewriting just the class inside its literal; a nearest
color or a spelling correction is a choice left to you or your agent. In
GitHub Actions, `--format github` turns findings into annotations on the pull
request.

## Exceptions

Document an intentional exception next to the code:

```heex
<%!-- heex-lint-disable-next-line no_raw_colors -- Partner brand color, approved by design. --%>
<span class="bg-amber-400">Sponsor</span>
```

`heex-lint-disable-line` and `heex-lint-disable-file` work too, in HEEx or
Elixir comments. `grep -rn "heex-lint-disable"` finds them all.

## Adopting it

Start with warnings, fix the common patterns, then promote rules to errors.
`mix heex_lint --max-warnings 287` fails CI when the count grows; add
`--quiet` to print only errors while the existing warnings are triaged. See
[docs/adoption.md](docs/adoption.md).

## Parity with @shadcn/lint

The six rules, the policy engine (`allow`, `deny`, contracts, categories,
groups, patterns, entry validation), messages and placeholders, theme reading
and the Tailwind oracle follow `@shadcn/lint` 0.2, down to its message text.
The class grammar is [cn](https://github.com/shadcn-ui/cn) 0.3.2's.

A parity check runs @shadcn/lint's own rules and HeexLint over equivalent
React and Phoenix projects, asking the same Tailwind: across 552 classes on
elements and components, with and without contracts and custom messages,
their 4,618 findings are identical. What changes for Phoenix is how components, variants, wrappers and
values are found. See [docs/parity.md](docs/parity.md).

## Acknowledgements

- [@shadcn/lint](https://github.com/shadcn-ui/lint) and
  [cn](https://github.com/shadcn-ui/cn) (MIT), whose rules, messages and
  grammar this ports.
- The HEEx tokenizer is vendored from
  [Phoenix LiveView](https://github.com/phoenixframework/phoenix_live_view) (MIT).
- The default palette and scales come from
  [Tailwind CSS](https://github.com/tailwindlabs/tailwindcss) (MIT).

## License

MIT
