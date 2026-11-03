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
dynamic-style checks. For a style value a library computes, see
[dynamic style identifiers](#dynamic-style-identifiers).

In `no_raw_colors`, `transparent`, `current` and `inherit` are always accepted.
`white` and `black` are accepted too, since Tailwind declares them in every
theme, until `deny` names them:

```elixir
no_raw_colors: {:error, deny: ["*-white", "*-black"]}
```

`<p class="text-white">` is then reported with the nearest theme tokens, such
as `text-background`. A theme that declares `--color-white` owns the name, and
it still passes.

Under `@import "tailwindcss" prefix(tw)`, `no_raw_colors` judges `tw:bg-pink-500`
and leaves `bg-pink-500` alone: it is no Tailwind class, and `no_unknown_classes`
reports it.

Tokens come from your theme and its imports. A design system installed as a
package contributes its tokens once the
[`theme_imports`](./design-systems.md#a-design-system-installed-as-a-package)
setting names its import.

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
| `ui`                | Module name prefixes added to the design system.               |
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
| `{{file}}`        | The relevant theme or component file; empty on `no_restyle` findings for a component from `deps/`. |

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
| `{{prop}}`     | The class attribute the classes were written in, such as `class` or `title_class`. |
| `{{sizes}}`    | Comma-separated size names on every finding, or empty.           |
| `{{where}}`    | Where to add a variant or size: `in lib/app_web/components/button.ex`, or `to <.button>` for a component from `deps/`. |
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
custom class by name, such as `allow: ["layout", "legacy-card"]`. A class your
CSS declares with `@utility` is classified by the properties its body sets, and
so is one from a package your theme imports: `@utility tap-target { min-height:
44px }` is layout, and tw-animate-css's `animate-in` and `fade-in` are motion.
One your CSS declares some other way, such as a plain selector, is still
unclassified — the rule cannot read what it changes — and is reported in words
that do not call it a misspelling.

A scale your `@theme` declares joins the grammar: `--radius-card` makes
`rounded-card` shape and `--text-display` makes `text-display` typography. A
`--radius-*: initial` reset replaces the default names, so `rounded-lg` is
unclassified until the theme declares it again.

The complete mapping is `HeexLint.Grammar.Categories`.

## Dynamic style identifiers

`no_inline_styles` reports a `style` value it cannot read. Some are computed by a
library, such as the position a floating element needs. Name them to allow them:

```elixir
no_inline_styles: {:error, allow_dynamic_identifiers: ["@floating_styles", "styles.popper"]}
```

```heex
<%!-- Allowed. --%>
<div style={@floating_styles} />

<%!-- Allowed, and color is still checked. --%>
<div style={[@floating_styles, "color: red"]} />

<%!-- Reported: another value. --%>
<div style={@other_styles} />
```

A name matches the read spelled the same way and nothing else, on any element or
component, in a `style` attribute or a map or keyword list spread onto a tag
(`{%{style: @floating_styles}}`):

| Name                      | Matches                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------- |
| `@floating_styles`        | `@floating_styles`: an assign in a template, a module attribute in a function body.                      |
| `assigns.floating_styles` | `assigns.floating_styles`, `assigns[:floating_styles]`, and `Map.get` or `Map.fetch!` on `assigns`.      |
| `floating_styles`         | That variable, however it is bound: in the function, in the function's head, by `:for` or `:let`.        |
| `styles.popper`           | That exact path, also as `styles[:popper]` or with `Map.get`, `Map.fetch!`, `Keyword.get`, `Keyword.fetch!`. `@styles.popper` and `assigns.styles.popper` work the same way. |
| `Floating.styles`         | A call to that function with the module as written, with any arguments or piped into.                    |

The spellings do not cover each other: `@floating_styles` is not
`assigns.floating_styles`, `styles` is not `styles.popper`, and `Floating.styles` is
not `MyApp.Floating.styles`. These have no name, so they stay reported: a local or
imported call such as `floating_styles()`, a string key such as `styles["popper"]`, a
computed key, and what a call returns, such as `Floating.styles(@anchor).popper`.

What the name holds decides the rest:

- A value written out where the name is bound is still checked, since it can be read:
  a string, `<>`, a sigil, a list, or a map, which stays reported as dynamic.
  `floating_styles = "color: red"` is reported.
- Any other value is exempt along with everything it goes on to read, literals
  included: `floating_styles = if assigns.open, do: "color: red", else: Floating.compute()`
  and an alias of another name both report nothing under `floating_styles`. So does a
  name bound more than once.
- Anything on the way counts. With `styles = Floating.compute()`, a `style={styles}`
  is allowed by `styles` or by `Floating.compute`.
- A value reached another way is still reported: with `allow_dynamic_identifiers:
  ["a"]`, `a = x`, `b = x` and `style={if @on, do: a, else: b}`, `x` is reported through
  `b`.

The option does not reach holes or forwarded styles. A hole, as in
`"--tone: #{tone}"`, is never reported for being unreadable, and a raw color in one is
reported whatever `tone` is called. A function component's received `style` is
already allowed, and its `attr` default is checked even if `@style` is listed, so an
unreadable default goes by its own name.

Entries must be strings shaped like these names. Anything else, such as
`assigns[:floating_styles]` or `Floating.styles()`, is a configuration error, since it
would match nothing. The option applies to the whole rule; a contract cannot set it.
