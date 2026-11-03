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

**Components you don't own.** A module the project imports, uses or aliases
that is not in the project is looked up in `deps/` by its conventional path
(`SaladUI.Button` in `deps/salad_ui/lib/salad_ui/button.ex`), a few levels
deep so `use SaladUI` brings in what its quote block imports. Its components
then resolve with their attrs, and `<.button>` from `import SaladUI.Button`
is SaladUI's, not a local one of the same name. A dependency's components are
the design system only when `ui` or `component_imports` names them. Their
findings list the dependency's variants and name the component rather than
its file: there is no variant to add inside `deps/`.

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
component's contract and suggestions. Chains resolve across files, at any
depth.

Each class prop follows its own path. A wrapper that hands `title_class` to
`card_title` gets `card_title`'s contract for it, while its `class` keeps
`card`'s:

```heex
attr :class, :any, default: nil
attr :title_class, :any, default: nil

def panel(assigns) do
  ~H"""
  <.card class={@class}>
    <.card_title class={@title_class}>{render_slot(@inner_block)}</.card_title>
  </.card>
  """
end

<%!-- Checked against card_title's contract, not card's. --%>
<.panel title_class="px-6" />
```

Global attributes carry any prop the component does not declare, as they do
when it renders. A class prop the wrapper does not hand to a design-system
component is not checked. If a prop lands on several tags, the first that is,
or wraps, a design-system component supplies the contract, reading a tag's
children before the tag and sibling tags in order. Classes on a wrapper's slot
use its `class` target, since a slot's attributes are not the wrapper's props.

## Theme tokens

The theme is the stylesheet that imports Tailwind, found under the Mix
project a file belongs to: when several do, the one declaring the most color
tokens wins, then the one nearest the root. In an umbrella, each app (each
directory with a `mix.exs`) finds its own, so files are checked against their
app's tokens, and `no_unknown_classes` asks that app's Tailwind. Set `theme`
to use one stylesheet everywhere. Its `@import`s are followed past symlinks;
files under `node_modules` contribute `@utility` names, class selectors and
`--animate-*` names from `@theme`, not tokens. A workspace package linked into
`node_modules` really lives outside it, so it counts as your own.

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

A class your CSS declares with `@utility` is classified by what its body sets,
the way an arbitrary property is: `@utility heading-2xs { font-size: 0.75rem }`
is typography, and `@utility max-w-chat { max-width: 48rem }` is layout. A body
that sets more than one thing takes the first appearance it carries, in the
order color, typography, spacing, shape, effects, motion, with layout last. A
class declared with a plain selector has no body to read and stays
`unclassified`.

The same holds for a package your theme imports. With `@import
"tw-animate-css"`, `animate-in` comes from the package's `@theme` and `fade-in`
or `slide-in-from-top-1` from its `@utility` rules, which set the custom
properties its enter and exit keyframes read, so all of them are `motion`.

A utility's own namespace counts too: `--background-color-surface` declares
`bg-surface` and nothing else. Theme namespaces that share a prefix with a
color utility are not colors: `--text-stat` makes `text-stat` a font size.

The grammar reads the scales your theme declares, the way `cn build` registers
them. A `--radius-card` in `@theme` makes `rounded-card` a shape class,
`--text-display` makes `text-display` typography, and `--spacing-gutter` makes
`p-gutter` spacing. A `--radius-*: initial` reset replaces the default names
with the declared ones, so `rounded-lg` is unclassified until the theme declares
it again, and `--*: initial` resets every scale but colors and fonts. Setting
`--spacing` after a reset brings the numeric spacing scale back. Only `@theme`
blocks count, from the same stylesheets as your tokens: installed packages
contribute no scales, and a linked workspace package does.

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
- further along a chain, up to 64 bindings: variables bound in the function,
  module attributes, same-module functions (each clause's result), map and
  keyword lookups (`Map.fetch!(@variants, @variant)` reads every entry), and
  merge functions.

Each binding is read once per attribute, so a class reached through both
branches of `if on, do: a, else: a` is one class. What cannot be read — a socket assign
in a LiveView, an unknown call, a variable that reads itself, a chain longer
than 64 bindings — is reported by `require_static_classes` when used on a
design-system component. A `style` has no such limit: `no_inline_styles` reads its
value however many bindings away, and reports what it cannot read as dynamic. A
hole in one, as in `"--tone: #{v}"`, is not reported for being unreadable either:
it is only looked through for raw colors.

## Where it looks

- `class` and other class attributes (`input_class`, `classes`...) on HTML
  tags, components and slots.
- `style` attributes and `<style>` elements; SVG color attributes `fill`,
  `stroke`, `color`, `stop-color`, `flood-color` and `lighting-color`.
- Merge-function calls anywhere in a module, and `attr :class` defaults.
- Every string literal, except plain map keys, when `scan_all_strings` is enabled on `no_raw_colors`
  or `no_arbitrary_values`.

## What it cannot see

- **Parent selectors.** `no_restyle` does not trace `[&_button]:bg-primary` to
  a child component. Token rules still check the class.
- **Unknown attribute maps.** `<.button {@attrs}>` is left alone, and a wrapper
  passing `{assigns}` or `{assigns_to_attributes(assigns)}` is not followed.
- **Other modules' values.** Values are followed within a module, not across
  modules; wrapper tracing only follows class props, in the tag that reads them.
  A prop renamed in the function body, as in `assign(assigns, :merged_class, ...)`
  reading `assigns.class`, is not followed to `@merged_class`.
- **Plain CSS.** Stylesheets and `@apply` are outside these rules.
- **Locally rebuilt components** are not the design system; token rules still
  apply to their classes.
- **New tokens and suppressions.** New `@theme` declarations are allowed by
  design, and `heex-lint-disable` comments bypass rules. Review those changes.
