# How it works

HeexLint reads your modules, templates and theme to check how you use them.
It analyzes source code without compiling or running your app.

## Components

Every `.ex`/`.exs` file under `inputs` is parsed. A function component is a
`def name(assigns)` with `attr`/`slot` declarations or a `~H` body, or a
`.heex` file embedded with `embed_templates`. A `.heex` file next to a
LiveView (`foo_live.html.heex` beside `foo_live.ex`) is its `render/1`.

Tags resolve the way the compiler does:

- `<.button>`: the current module's `button/1`, then the modules it imports,
  including those a `use MyAppWeb, :html` brings in through the web module's
  quote blocks (`unquote(html_helpers())` included).
- `<Layouts.app>`: through the module's aliases, then as written.
- `<:col>`: a slot belongs to the component it is passed to.

Name matching across the project is a fallback only when imports cannot be
read. Phoenix's own components (`link`, `form`, `inputs_for`...) are not the
project's.

**The design system** is the set of modules whose components `no_restyle`
and `require_static_classes` check: every module defined under a
`components/` directory, plus the modules `ui` names by prefix
(`"MyAppWeb.UI"` matches it and `MyAppWeb.UI.*`) and `component_imports`
matches by regex. `ignore_imports` excludes modules and takes precedence.

**Variants** come from `attr` declarations: `values:` on an attribute named
`variant` lists the component's variants, and on `size` its sizes.

**Wrappers.** A component outside the design system that forwards its
received `class` — `class={["w-full", @class]}` — or its global attributes —
`{@rest}` with `attr :rest, :global` — to a design-system component gets that
component's contract and suggestions. Chains resolve across files, a few
hops deep.

## Theme tokens

The theme is the stylesheet that imports Tailwind, found under the Mix
project a file belongs to: when several do, the one declaring the most color
tokens wins, then the one nearest the root. In an umbrella, each app (each
directory with a `mix.exs`) finds its own, so files are checked against their
app's tokens, and `no_unknown_classes` asks that app's Tailwind. Set `theme`
to use one stylesheet everywhere. Its `@import`s are followed;
files under `node_modules` contribute `@utility` names and class selectors,
not tokens.

Color tokens are the `--color-*` declarations in `@theme`, with resets
(`--color-*: initial`) applied in cascade order:

```css
@theme inline {
  --color-primary: var(--primary);
  --color-brand: var(--brand);
}
```

- `bg-brand` is allowed: it names a declared token.
- `bg-zinc-100` is reported: it uses a raw palette color.
- `bg-highlight` is reported: it names an undeclared token.

A utility's own namespace counts too: `--background-color-surface` declares
`bg-surface` and nothing else. Theme namespaces that share a prefix with a
color utility are not colors: `--text-stat` makes `text-stat` a font size.

Suggestions use token values: variables resolve from `:root`, dark-mode
blocks are skipped, and colors compare in OKLab. The radius and text scales
(and `calc()`) are read too, so `rounded-[10px]` can suggest `rounded-lg`
when that token is 10px, and `--spacing` sets the unit for exact spacing
steps.

## Tailwind classes

`no_unknown_classes` asks your installed Tailwind v4 whether each class
generates CSS, with your theme's imports, custom utilities, variants and
plugins:

- **Node.** When `tailwindcss` resolves from the theme's directory, a Node
  process loads the design system through `@tailwindcss/node` (the loader
  Tailwind's own CLI and Vite plugin use) and suggests the nearest real class
  or variant.
- **Standalone CLI.** Otherwise, the binary the `tailwind` hex package
  installs in `_build/` (or `tailwind_bin`) builds your theme with the
  candidates as `@source inline(...)`; a class is known when its selector is
  in the output. No suggestions this way.
- **Grammar.** Without either, the class grammar, `@utility` names and class
  selectors answer; that checks less.

## Values

A class value is read through:

- strings, `~w(...)`, lists, `if`/`unless`/`case`/`cond`/`with`, `&&`, `||`;
- interpolation and `<>`, where text glued to a runtime value
  (`"bg-#{@tone}"`) is no class of its own and the value is unreadable, while
  a value standing alone (`"px-2 #{@extra}"`) is read on its own;
- in a template, `@name` follows `assign(assigns, :name, ...)`,
  `assign_new` and `update` in the rendering function;
- in a function component, the received `class` (and any `*_class`) is the
  component's own input: accepted as-is, with its `attr` default checked;
- one hop further: variables bound in the function, module attributes,
  same-module functions (each clause's result), map and keyword lookups
  (`Map.fetch!(@variants, @variant)` reads every entry), and merge functions.

What cannot be read — a socket assign in a LiveView, an unknown call — is
reported by `require_static_classes` when used on a design-system component.

## Where it looks

- `class` and other class attributes (`input_class`, `classes`...) on HTML
  tags, components and slots.
- `style` attributes and `<style>` elements; SVG color attributes `fill`,
  `stroke`, `color`, `stop-color`, `flood-color` and `lighting-color`.
- Merge-function calls anywhere in a module, and `attr :class` defaults.
- Every string literal when `scan_all_strings` is enabled on `no_raw_colors`
  or `no_arbitrary_values`.

## What it cannot see

- **Parent selectors.** `no_restyle` does not trace `[&_button]:bg-primary` to
  a child component. Token rules still check the class.
- **Unknown attribute maps.** `<.button {@attrs}>` is left alone.
- **Other modules' values.** Values are followed within a module, not across
  modules; wrapper tracing only follows `class` forwarding.
- **Plain CSS.** Stylesheets and `@apply` are outside these rules.
- **Locally rebuilt components** are not the design system; token rules still
  apply to their classes.
- **New tokens and suppressions.** New `@theme` declarations are allowed by
  design, and `heex-lint-disable` comments bypass rules. Review those changes.
