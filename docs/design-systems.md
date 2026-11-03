# Configuring your design system

Use variants for appearances you want to reuse. Use contracts to define which
styling changes a page can make.

Start with the [README setup](../README.md#quickstart). For an existing
codebase, follow [Adding linting to an existing project](./adoption.md).

## Variants

Use a variant for a named appearance that callers should reuse:

```heex
<.button variant="destructive">Delete</.button>
```

If an existing variant fits, use it. When the design needs a new treatment,
add it to the component. For example, a brand variant can use these tokens:

```css
@theme {
  --color-brand: #ec4899;
  --color-brand-foreground: #fff;
}
```

Add it to the component's `attr` and its classes:

```elixir
attr :variant, :string, values: ~w(primary destructive brand), default: "primary"

defp button_variant("brand"), do: "bg-brand text-brand-foreground hover:bg-brand/90"
```

Then use it by name:

```heex
<.button variant="brand">Subscribe</.button>
```

The linter reads the new variant from `values:` and suggests it in later
findings. Sizes work the same way through `attr :size, values: [...]`.

## Contracts

Use a contract when callers should control part of a component's styling.
Titles might accept typography while avatars accept only size:

```elixir
no_restyle: {:error, allow: ["layout"], contracts: [
  [pattern: "^card_title$", allow: ["layout", "typography"]],
  [pattern: "(content|footer)$", allow: ["layout", "spacing"], deny: ["p-0", "px-0"]],
  [pattern: "^avatar$", allow: ["size-*"]]
]}
```

- `pattern` matches component function names with a regex.
- `allow` is the complete list of what the component accepts. Include
  `layout` if callers may place it.
- `deny` rejects classes `allow` would otherwise cover.

The top-level options apply to components without a matching contract. A
contract replaces the keys it writes and inherits the rest; if several
match, only the last one applies. Entries can be categories (`spacing`),
class groups (`bg-color`) or patterns (`size-*`).

```heex
<%!-- Passes. --%>
<.card_title class="text-sm">Account settings</.card_title>
<.avatar class="size-8" />

<%!-- Reports a contract violation. --%>
<.avatar class="w-full" />
<.card_content class="px-0" />
```

Containers whose padding and gap belong to the page can open spacing:

```elixir
[pattern: "^card$|(content|header|footer|group|panel)$", allow: ["layout", "spacing"]]
```

Spacing findings then point at them: *"For space around it, use margin
here, spacing on `<.card_header>`, or .card, .card_footer and .card_content."*

Contracts do not bypass other rules. Allowing padding on a component still
leaves `p-[13px]` subject to `no_arbitrary_values`.

## Custom messages

Write guidance that explains your team's decisions. A contract can use one
message for all findings, or one per category:

```elixir
[
  pattern: "^button$",
  allow: ["layout"],
  deny: ["w-*"],
  message: %{
    layout: "Set width on the parent container.",
    spacing: "Use a button size: {{sizes|none defined}}.",
    default: "Use a button variant: {{variants|none defined}}."
  }
]
```

For `<.button class="w-full">`, the message is *"Set width on the parent
container."* Placeholders use the component's actual names and values; see
[Your own words](./rules.md#your-own-words). Every rule also accepts a
`message`, and the `note` setting is appended to every finding.

## A design system installed as a package

A stylesheet under `node_modules` contributes `@utility` names and classes but
no tokens, so Tailwind's palette is not your vocabulary. A design system
published to npm falls under the same rule: once your theme declares one color
of its own, every color of the package reads as undeclared. Name its import with
`theme_imports`:

```elixir
# .heex_lint.exs
[
  settings: [theme_imports: ["^@acme/ui/"]]
]
```

```css
/* assets/css/app.css */
@import "tailwindcss";
@import "@acme/ui/theme.css";
```

Each pattern is a regex, as a string or a `Regex`, on the `@import` as written.
`@acme/ui/theme.css` then counts as your own: its tokens, scales, values and
resets. So do the stylesheets it imports from within the same package. Another
package it imports does not until a pattern names it, and its own
`@import "tailwindcss"` stays out, so Tailwind's palette is still reported. A
pattern that is not a valid regex warns once and is ignored.

`theme_imports` is a setting only; rules do not accept it as an option. In an
umbrella it applies to every app's theme.

### A stylesheet from a Hex package

This needs no setting. `deps/` is not `node_modules`, so a stylesheet there,
and whatever it imports by path, already counts as your own:

```css
@import "../../deps/my_kit/priv/static/theme.css";
```

The same goes for a dependency linked from `assets/package.json` with
`"my_kit": "file:../deps/my_kit"`, which resolves to `deps/my_kit`.

## Share a policy

`.heex_lint.exs` is Elixir, so a policy can live in its own file and be
shared across projects or apps:

```elixir
# design_system.exs
[
  no_restyle: {:error, allow: ["layout"], contracts: [
    [pattern: "^card_title$", allow: ["layout", "typography"]]
  ]},
  no_raw_colors: :error
]
```

```elixir
# .heex_lint.exs
{policy, _} = Code.eval_file("design_system.exs")

[
  rules: policy ++ [no_unknown_classes: :warning],
  overrides: [[files: ["lib/my_app_web/components/**"], rules: [no_restyle: :off]]]
]
```

## Review changes

Run `mix heex_lint` in CI (`--format github` annotates pull requests) and
make it part of your agents' instructions. Review new tokens, variants,
contracts and `heex-lint-disable` comments as design decisions: the linter
checks the configured rules; it cannot decide whether a new appearance
belongs in the system.
