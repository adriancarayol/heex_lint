# Rules

Enable each rule at `:warning` or `:error` in `.heex_lint.exs`. Each rule's
module documents its examples and options:

| Rule                     | What it checks                                         |
| ------------------------ | ------------------------------------------------------ |
| `no_restyle`             | Classes passed to design-system components.            |
| `no_raw_colors`          | Palette colors, undeclared tokens, and raw SVG colors. |
| `no_arbitrary_values`    | Arbitrary values such as `p-[13px]`.                   |
| `no_inline_styles`       | Inline styles and `<style>` elements.                  |
| `no_unknown_classes`     | Classes the project's Tailwind cannot generate.        |
| `require_static_classes` | Unreadable class values on components.                 |
| `no_unknown_variables`   | CSS variables the theme does not define. *(HeexLint)*  |

Turn `no_restyle` off inside your component directory so components can
style themselves; do the same for `no_arbitrary_values` and
`require_static_classes`. The recommended config includes that override.

## Shared options

### The policy

Every rule accepts `message`. Every rule except `require_static_classes`
also accepts `allow`, `deny` and `contracts`:

| Option      | What it does                                                            |
| ----------- | ----------------------------------------------------------------------- |
| `allow`     | Allows matching classes or properties through this rule.                |
| `deny`      | Removes matches from `allow`. Without `allow`, permits everything else. |
| `contracts` | Sets a policy for matching components.                                  |
| `message`   | Replaces the rule's error text.                                         |

For `no_restyle`, these options decide which classes a component accepts.
For the token and class-existence rules, they define exceptions to the
check. For `no_inline_styles`, they apply to CSS property names.

```elixir
no_restyle: {:error, allow: ["layout"], deny: ["w-*"]}
```

Margin passes. Width does not. Appearance classes are still reported.

An omitted `allow` and an empty `allow` differ when `deny` is present:

| Configuration                 | Policy                                          |
| ----------------------------- | ----------------------------------------------- |
| Neither `allow` nor `deny`    | No policy exceptions.                           |
| `allow: [...]`                | Only matching classes or properties are exempt. |
| `allow: []`                   | No policy exceptions.                           |
| `deny: [...]` without `allow` | Everything except these matches is exempt.      |
| `deny: []` without `allow`    | Everything is exempt.                           |

The policy only affects what the rule checks: `deny: ["bg-primary"]` does
not make a declared token a raw color, class exceptions do not bypass SVG
attribute checks, and property exceptions do not bypass `<style>` or
dynamic-style checks.

### Contracts

A contract's `pattern` is a regex on the component's function name:
`^button$` matches only `<.button>`; `button` also matches `<.icon_button>`.
Write contracts as keyword lists or maps:

```elixir
no_raw_colors: {:error, allow: ["*-amber-*"], deny: ["bg-amber-500"], contracts: [
  [pattern: "^badge$", allow: ["*-amber-500"], deny: []]
]}
```

A contract replaces the keys it writes and inherits the rest from the
top-level rule. If several contracts match, only the last one applies. Above,
outside `<.badge>` amber classes pass except `bg-amber-500`; on `<.badge>`
only amber-500 classes are exempt, and `deny: []` clears the inherited
denial. Declared theme colors pass in both cases.

For `no_inline_styles`, contracts match the component name as written
(`button` for `<.button>`, `Layouts.app` for `<Layouts.app>`), without
resolving wrappers. HTML elements use the top-level policy.

Class rules accept these entries in `allow` and `deny`:

| Entry            | Example                          | What it matches                     |
| ---------------- | -------------------------------- | ----------------------------------- |
| Category         | `layout`, `spacing`, `color`     | Classes in that category.           |
| Class group      | `p`, `px`, `bg-color`, `rounded` | Values in that group.               |
| Class or pattern | `p-4`, `p-*`, `md:p-*`           | An exact class or wildcard pattern. |

Groups are separate: `p` does not include `px` or `py`; `rounded` does not
include `rounded-t-*`. An entry that is both a group and a class matches
both: `flex` covers `flex` and `flex-1`.

Entries without `:` match the base class, ignoring variants, important
markers, negative prefixes and opacity modifiers: `p-*` matches `md:!p-4`;
`bg-primary` matches `bg-primary/50`. Entries containing `:` match the full
class: `[margin:*]` matches `[margin:1rem]`, not `md:[margin:1rem]`.

These are class-name checks, not checks for equivalent CSS effects. `w-*`
does not cover `inline-full` or `[width:100%]`. Allowing `p-*` also allows
`p-[13px]` through `no_restyle`; `no_arbitrary_values` still checks the value.

Invalid regexes and misspellings of a category or class group such as
`spacig` are configuration errors: reported on line 1 of each file, pausing
the rule there. Other unknown names, such as a plugin's `prose` or a custom
`btn`, may be real classes, so they only warn and match a class named exactly
that. `no_unknown_classes` accepts unknown entries, since they may name
external classes.

### Recognition

Every rule except `no_inline_styles` accepts these options, which override
the shared settings of the same name:

| Option              | What it does                                                   |
| ------------------- | -------------------------------------------------------------- |
| `ui`                | Module name prefixes of the design system.                     |
| `component_imports` | Regexes on module names that are also the design system.       |
| `ignore_imports`    | Regexes on module names that never are. Takes precedence.      |
| `merge_functions`   | Adds functions whose arguments contain classes.                |
| `variant_functions` | Adds functions whose map or keyword values contain classes.    |

The built-in merge functions are `cn`, `Tails.classes`, `TwMerge.merge` and
`Twix.tw`. Inside class values, `Enum.join`, `Enum.filter`, `Enum.reject`,
`Enum.uniq`, `Enum.concat`, `List.flatten`, `List.wrap` and `String.trim`
are read through as well.

### Your own words

Set `message` to replace a rule's error text:

```elixir
no_raw_colors: {:error, message: ~s(Use a theme color for "{{className}}". See {{file}}.)}
```

Every finding provides these placeholders, empty when they do not apply:

| Placeholder       | Value                                                     |
| ----------------- | --------------------------------------------------------- |
| `{{className}}`   | The class, or an SVG attribute such as `fill="#f00"`. Also `{{class}}`. |
| `{{property}}`    | The inline CSS property.                                  |
| `{{component}}`   | The component, such as `.button`.                         |
| `{{suggestions}}` | Suggested tokens, scale values, or a spelling correction. |
| `{{file}}`        | The relevant theme or component file.                     |

`no_restyle` also accepts a map with category keys: `layout`, `color`,
`typography`, `spacing`, `shape`, `effects`, `motion`, and `default` for the
rest, including unclassified names. A contract can provide its own message
in the same format; its category message wins, then its `default`, then the
rule's message, then the built-in guidance.

Additional `no_restyle` placeholders:

| Placeholder    | Value                                                            |
| -------------- | ---------------------------------------------------------------- |
| `{{category}}` | The class category, including `layout` or `unclassified`.        |
| `{{variants}}` | Comma-separated variant names, or empty.                         |
| `{{wrapper}}`  | The forwarding component, or empty.                              |
| `{{sizes}}`    | Size names on spacing findings, except explicit `deny` findings. |
| `{{around}}`   | Where spacing can go instead, on spacing findings.               |
| `{{entries}}`  | The relevant allow or deny entries.                              |

Other rules provide these on the findings that use them:

| Placeholder       | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| `{{tokens}}`      | Declared color names on color findings, up to 12.                      |
| `{{suggestion}}`  | The corrected class on spelling findings; the nearest token on SVG attribute findings. |
| `{{replacement}}` | The equivalent scale or token class on `no_arbitrary_values` findings. |
| `{{attribute}}`   | The SVG attribute name, such as `fill`.                                |
| `{{value}}`       | That attribute's value, such as `#f00`.                                |

Use `{{variants|none defined}}` for a fallback when a value is empty. Unknown
placeholders stay literal, including their fallback; likely typos warn.
Messages are limited to 500 characters. The `note` setting is appended to
every finding, custom messages included.

## Categories

Under `no_restyle` with `allow: ["layout"]`:

| Category     | Examples                                           | Result    |
| ------------ | -------------------------------------------------- | --------- |
| layout       | `mt-4`, `w-full`, `hidden`, `absolute`, `flex-1`   | Allowed.  |
| color        | `bg-primary`, `text-red-500`, `border-border`      | Reported. |
| typography   | `text-sm`, `font-bold`, `leading-none`, `truncate` | Reported. |
| spacing      | `p-4`, `gap-2`, `space-x-4`                        | Reported. |
| shape        | `rounded-lg`, `border`, `ring-2`, `outline-none`   | Reported. |
| effects      | `shadow-sm`, `opacity-50`, `blur`, `backdrop-blur` | Reported. |
| motion       | `animate-pulse`, `transition`, `duration-200`      | Reported. |
| unclassified | `flex-cols`, a custom class unknown to the grammar | Reported. |

Margin, transforms and text alignment are layout. Padding and gap are
spacing. Markers such as `group`, `group/name` and `peer` pass with layout
allowed. `unclassified` is a reported category, not an allowance: allow a
custom class by name, such as `allow: ["layout", "tap-target"]`. A class your
CSS declares with `@utility`, or as a plain selector, is still unclassified —
the rule cannot read what it changes — and is reported in words that do not
call it a misspelling.

The complete mapping is `HeexLint.Grammar.Categories`.
