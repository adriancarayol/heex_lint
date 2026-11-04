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
`node_modules` really lives outside it, so it counts as your own, and so does a
stylesheet under `deps/`. A design system installed as a package counts once the
[`theme_imports`](./design-systems.md#a-design-system-installed-as-a-package)
setting names its import, with the stylesheets it imports from within the package.

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
contribute no scales, and a linked workspace package or a package `theme_imports`
names does.

Suggestions use token values: variables resolve from `:root`, dark-mode
blocks are skipped, and colors compare in OKLab. The radius and text scales
(and `calc()`) are read too, so `rounded-[10px]` can suggest `rounded-lg`
when that token is 10px, and `--spacing` sets the unit for exact spacing
steps. A value that would grow past 100,000 characters, counted in UTF-16 units as
JavaScript counts them, such as one whose variables name each other many times over,
stays unresolved, like one with no value.

## Tailwind classes

`no_unknown_classes` asks your installed Tailwind v4 whether each class
generates CSS, with your theme's imports, custom utilities, variants and
plugins:

- **Node.** When `tailwindcss` resolves from the theme's directory, or from the
  directory of a stylesheet the theme imports that imports Tailwind, a Node process
  loads the design system and suggests the nearest real class or variant. In a
  workspace or an umbrella, that second place is where only a UI package depends on
  Tailwind. Node follows a package's `style` condition to find it, so only Node can
  say: it starts when any `node_modules` is in reach of those stylesheets, and moves
  on without a word when none holds Tailwind. The same goes for a `node` that exits
  before its first answer, such as a version manager's shim with no version set,
  though what it prints still reaches the terminal. Plugins and configs load through
  `@tailwindcss/node` when it is installed (the loader Tailwind's own CLI and Vite
  plugin use), and otherwise through Node's own `import()`.
- **Standalone CLI.** Otherwise, the binary the `tailwind` hex package
  installs in `_build/` (or `tailwind_bin`) builds your theme with the
  candidates as `@source inline(...)`; a class is known when its whole selector
  is in the output. The output cannot say which rule a name came from, so a name
  only another rule mentions, such as `qux` beside `[&_.qux]:flex`, counts as known.
  No suggestions this way, so `no_raw_colors` keeps a typo such as `text-smal`
  rather than handing it to this rule.
- **Grammar.** Without either, the class grammar, `@utility` names and class
  selectors answer, with no warning; that checks less.

The other rules ask too, in three cases. `no_raw_colors` asks about a class it would
report as an undeclared color, in case that is a typo of another utility. Every rule
that checks contract entries asks about one nothing else knows, since a plugin's class
is in no stylesheet, and a theme that loads an `@config` or `@plugin` has its own Tailwind
answer for the `text-*` classes the grammar reads as colors, since one may be a font
size. With no such question, Node does not start. The standalone binary answers the
last from the rule it generates for the class under a variant that changes nothing,
`[&]:text-body`: no stylesheet has a rule of that name, where one for `text-body` may be
the theme's own. Since each question is a build there, the first such question also asks
about the `text-*` classes the linted files and the contract entries name.

Tailwind cannot outlive the linter or stall it. Through Node, the linter waits up to 60
seconds for a stylesheet's first answer and 30 seconds for later ones. Through the
standalone binary it waits up to 60 seconds for each question, however many builds that
takes. Set `HEEX_LINT_TAILWIND_TIMEOUT` to a number of milliseconds to change all of
these, and anything but a positive number is ignored. A process past that wait is
killed, with whatever it started but a child a plugin detaches, and that stylesheet uses
the grammar for the rest of
the run, with a warning. Another stylesheet gets a new process, and two failures with no
good answer between them turn Tailwind off for the run. The Node process also ends
within moments of the linter going away, however it goes and whatever a plugin is doing,
and the standalone binary is stopped the same way.

A class longer than 10,000 characters or with more than 64 variants is not judged, since
Tailwind can stall or overflow its stack on one. Neither is a class that makes a plugin
throw: Node asks about it alone, and the standalone binary, where a throw fails the
whole build, searches for it once a build fails and the theme builds without any
classes. When the build reaches that class, through the stylesheet's own `@source` or
through Tailwind's automatic detection from the stylesheet's directory, as for a theme at
the project root or under `lib/`, the theme does not build without it either, so that
stylesheet uses the grammar, with a warning. A build
with `@import`s that reach more than 10,000 stylesheets is refused through Node, as
those form a cycle with fan-out: Tailwind reads a file again wherever it is imported and
stops only 100 levels down. The standalone binary is not tried after that. Without Node
it has only the wait to stop such a theme, and can use several gigabytes by then.

Under `@import "tailwindcss" prefix(tw)`, only `tw:flex` is a Tailwind class.
`no_raw_colors` judges the class behind the prefix and leaves an unprefixed one
alone, and `no_unknown_classes` reports the unprefixed one, a color like `text-muted`
as much as `flex`. The prefix is read from the project's own stylesheets, the first
one read winning, and from the stylesheet Tailwind builds when `theme` names a partial.
An installed package does not declare it, even one `theme_imports` names.
The grammar knows no prefix, so without a Tailwind to ask an unprefixed class passes
`no_unknown_classes`.

## Values

A class value is read through:

- strings, `~w(...)`, lists, `if`/`unless`/`case`/`cond`/`with`, `&&`, `||`;
- interpolation and `<>`, where text glued to a runtime value
  (`"bg-#{@tone}"`) is no class of its own and the value is unreadable, while
  a value standing alone (`"px-2 #{@extra}"`) is read on its own;
- in a template, `@name` and `assigns.name` follow `assign(assigns, :name, ...)`,
  `assign_new` and `update` in the rendering function, and so does a lookup on them
  (`@name.key`);
- in a function component, the received `class` (and any `*_class`) is the
  component's own input: accepted as-is, with its `attr` default checked;
- further along a chain, up to 64 bindings: variables bound in the function,
  module attributes, same-module functions (each clause's result), map and
  keyword lookups (on a variable or a module attribute, `Map.fetch!(@variants, @variant)`
  reads every entry; on `%{base | a: value}` or a table assigned with `assign/3`, the key
  it writes, or its base's, and any other is unreadable), and merge functions.

Each binding, and each function an embedded template calls, is read once per attribute, so
a class reached through both branches of `if on, do: a, else: a` is one class. What cannot be read — a socket assign
in a LiveView, an unknown call, a variable that reads itself, a chain longer
than 64 bindings — is reported by `require_static_classes` when used on a
design-system component. A `style` has no such limit: `no_inline_styles` reads its
value however many bindings away, and reports what it cannot read as dynamic, unless
[`allow_dynamic_identifiers`](rules.md#dynamic-style-identifiers) names it or a value
it was read through. A hole in one, as in `"--tone: #{v}"`, is not reported for being
unreadable either: it is only looked through for raw colors.

## Where it looks

- `class` and other class attributes (`input_class`, `classNames`...) on HTML
  tags, components and slots.
- `style` attributes and `<style>` elements; SVG color attributes `fill`,
  `stroke`, `color`, `stop-color`, `flood-color` and `lighting-color`, quoted or as a
  literal in braces, `fill={"red"}`.
- `attr :class` defaults.
- Merge-function calls anywhere a file's code is read. In Elixir code, that is in a function,
  its `rescue` and the like included, or out of one, such as a module attribute or a default
  argument. In a template, it is in a `{...}`,
  `<%= ... %>`, `:if` or `:for`, whatever surrounds the call. A call a class attribute reads
  is that attribute's, so a component's contract decides it. Any other call, as in
  `title={cn("bg-pink-500")}` or `class={foo(cn("bg-pink-500"))}`, is checked on no
  component: no contract reaches it, and `no_restyle` and `require_static_classes` say
  nothing about it.
- With `scan_all_strings` on `no_raw_colors` or `no_arbitrary_values`, every string literal
  with a hyphen: in Elixir code, in quoted attribute values, and in a template's `{...}` and
  `<%= ... %>`, `:if` and `:for` included. Plain map keys are skipped. Text between tags, an
  interpolated string and a sigil are not literals here, though a class site reads the last
  two. A `@doc` string is one.

Files come from `inputs`, without any path that has a directory named `deps` in it.

## What it cannot see

- **Parent selectors.** `no_restyle` does not trace `[&_button]:bg-primary` to
  a child component. Token rules still check the class.
- **Unknown attribute maps.** `<.button {@attrs}>` is left alone, and a wrapper
  passing `{assigns}` or `{assigns_to_attributes(assigns)}` is not followed.
- **Other modules' values.** Values are followed within a module, not across
  modules; wrapper tracing only follows class props, in the tag that reads them.
  A prop renamed in the function body, as in `assign(assigns, :merged_class, ...)`
  reading `assigns.class`, is not followed to `@merged_class`, and a wrapper's
  `<:title class={@title_class}>` inside a component is not followed either.
- **Keyword lists in a merge call.** A map's keys are read as classes, as in
  `cn(%{"bg-pink-500" => @on})`. `cn(rounded: @on)` is not, since a keyword list is how
  Elixir passes options.
- **Templates with no function around them.** A `~H` in a module attribute, a `quote` outside
  a `def` or a `def` inside an `if` is read, but what it does not hold itself cannot be
  followed, so a variable in it is dynamic. A `~H` directly in a `defimpl`, or a module
  inside an `if` or a `quote`, is not read by any rule. A module inside a `defimpl` is read
  as any other module is.
- **EEx tags a block splits.** `<% end) |> cn() %>` does not parse once its `end` is taken
  off, so no rule reads what is in it. `<% end, cn("bg-pink-500")) %>` is read, and so is
  `<%= Enum.map(cn("bg-pink-500"), fn x -> %>`.
- **Patterns.** `%{a: s} = %{a: "color: red"}` does not read `s`, which is dynamic.
- **Plain CSS.** Stylesheets and `@apply` are outside these rules.
- **Locally rebuilt components** are not the design system; token rules still
  apply to their classes.
- **New tokens and suppressions.** New `@theme` declarations are allowed by
  design, and `heex-lint-disable` comments bypass rules. Review those changes.
