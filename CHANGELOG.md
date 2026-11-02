# Changelog

## Unreleased

- A chain of variables, attributes, functions and lookups is followed for 64
  bindings instead of 4, and the next one is unreadable, as in @shadcn/lint.
  **This adds findings:** a class more than four links away is now checked by
  every rule, where it was dropped without a word, and a chain past 64 is
  reported by `require_static_classes`, or by `no_inline_styles` for a `style`,
  at the read that goes past the limit. A binding is read once per site, so a
  generated chain of `if on, do: a, else: a` stays linear, also past the limit
  or ending in a cycle.
- A variable a template reads directly, as in `<.button class={v}>`, is read
  where the function binds it. **This adds findings:** its classes used to be
  dropped, and now get reports and fixes at that place. `@name` in its value is
  a module attribute, not an assign.
- Two functions can each have a variable of one name. One calling the other
  read as a cycle, reported as dynamic; its classes are now read. **This adds
  findings** for those classes and removes the dynamic one.
- A lookup on a table that names itself (`t = t`, `@t @t`, `t = %{a: t[:a]}`)
  no longer hangs the run. It is reported as dynamic.
- A workspace package linked into `node_modules`, as pnpm and npm workspaces
  do, counts as your own, as in @shadcn/lint: imports resolve to their real
  path, and a package can import itself by name. Its tokens, scales and resets
  now apply. **This adds findings:** its colors become the tokens
  `no_raw_colors` checks against, its `--radius-*: initial` makes `rounded-lg`
  unrecognized, and its `--radius-card` makes `rounded-card` a shape class that
  `no_restyle` reports. A stylesheet reached through a link and by its real path
  is read once.
- The grammar reads the scales your theme declares, the way `cn build`
  registers them (cn 0.4.0). `--radius-card` makes `rounded-card` a shape
  class, and `--tracking-*`, `--leading-*`, `--blur-*`, `--ease-*`,
  `--aspect-*`, `--spacing-*`, `--perspective-*`, `--breakpoint-*`,
  `--container-*`, `--font-weight-*`, `--animate-*` and the shadow and text
  namespaces work the same way. `no_restyle` now reports these under their
  category and passes them when a contract allows it, and they stop being
  unclassified. **This adds findings:** `--radius-*: initial` replaces the
  default names with the declared ones, so `rounded-lg` is unrecognized until
  the theme declares it again, and `--*: initial` does this to every scale. A
  `shadow-lg` or `text-lg` after such a reset reads as a color, so
  `no_raw_colors` reports it as undeclared, and `no_restyle` as color rather
  than effects or typography. `--spacing` set after a reset keeps the numeric
  spacing scale. A `deny` or `allow` reaching a category now reaches the
  declared classes too. After `--animate-*: initial`, `animate-spin` is
  unrecognized under `@import "tailwindcss"`, but stays a motion class when
  the theme imports `tailwindcss/theme.css` or `tailwindcss/index.css` by
  path, as in @shadcn/lint.
- `--text-primary` beside `--color-primary` makes `text-primary` a font size,
  and `no_raw_colors` does not check it. The grammar's answer now wins over a
  color token of the same name for `text-*`, as it already did for `shadow-*`.
  Only `bg-*`, reading `--background-image-*`, still gives way to a color.
- A stylesheet reached by two import paths is read once, at the first, as
  upstream does. Reading it again put its declarations over the ones read
  between the two imports, so a utility body or a `:root` value could come
  from the wrong file. This can change the category `no_restyle` reports and
  the values the theme resolves in projects whose imports overlap. The limit of
  65 stylesheets now counts the whole import tree rather than one import chain.
- `no_restyle` classifies a class your CSS declares with `@utility` by the
  properties its body sets, nested rules and custom properties included:
  `@utility tap-target { min-height: 44px }` is layout and passes
  `allow: ["layout"]`, and `@utility heading-2xs { font-size: 0.75rem }` is
  reported as typography. A body setting several things takes the first
  appearance, so `display` plus `color` is color. Exact names win over
  prefixes such as `@utility tab-*`. A body-less `@utility` and a plain
  selector stay unclassified. This removes findings for utilities your
  contract's categories cover. **It adds findings** where the new category is
  not allowed or is denied: `deny: ["typography"]` now reaches `heading-2xs`,
  and `@utility text-md-regular { font-size: 1rem }`, which the grammar read as
  a color, no longer passes `allow: ["color"]`.
- With `@import "tw-animate-css"`, its `animate-in`, `fade-in`,
  `slide-in-from-top-1` and the rest are motion, as are any `--tw-enter-*`,
  `--tw-exit-*` and `--tw-animation-*` arbitrary properties. Packages now
  contribute the `--animate-*` names of their `@theme`. **This adds findings**
  where `deny` names motion, and removes them where `allow` does.
- A commented-out `@utility` no longer counts as declared. **This adds
  findings** for a class only such a comment named, the way Tailwind treats it.

- `no_raw_colors` reports `white` and `black` where `deny` names them, as in
  `no_raw_colors: {:error, deny: ["*-white", "*-black"]}`, and suggests the
  nearest theme tokens. **This adds findings** for a config whose `deny`
  matches those classes, which were accepted before: `deny: ["*-white"]`, or
  a `deny` naming a category or group that covers them. Without such a
  `deny` they still pass, and a theme declaring `--color-white` still owns it.
- `{{sizes}}` in a custom `no_restyle` message now holds the size names on
  every finding, and is empty when the component has none, instead of
  printing the placeholder on a color or layout finding. Every `no_restyle`
  finding also offers `{{where}}`.
- `no_restyle` no longer sends anyone to add a variant or size in `deps/`. A
  finding on a component from a dependency says "Add a new variant to
  <.button>" instead of naming the file, and `{{file}}` is empty there.
  Messages for your own components are unchanged, and no findings are added.
- Theme variables resolve from `:root`, `html`, `:host` and `@theme` over
  scoped selectors such as `.compact`, across imported files too. Before,
  with `:root { --radius: 8px; }`, `.compact { --radius: 4px; }` and
  `--radius-card: var(--radius)`, `no_arbitrary_values` called
  `rounded-[4px]` an exact match for `rounded-card`, and `--fix` wrote that
  class, which is 8px at `:root`. It now writes `rounded-sm`. Scoped values
  still apply to variables nothing else sets.
- When several scale steps have the same value, `no_arbitrary_values` names
  the one declared first, Tailwind's own steps before the theme's, instead
  of the first by name. `--fix` writes that step.
- Neither change adds findings: they change which step or token is suggested
  or fixed to.
- `data-*` and `aria-*` attributes such as `data-class` are no longer read as
  class lists, so their values reach no class rule, and a component passing
  `@class` only through `data-class` no longer counts as forwarding it. This
  removes findings and adds none.
- `no_raw_colors` accepts `--border-color-*` tokens for `divide-*`, the way
  Tailwind falls back from `--divide-color-*`, and offers them for a mistyped
  `divide-*` class. This removes findings and adds none.
- A color function whose channels are one theme variable, such as
  `oklch(var(--primary-oklch) / 0.2)`, is no longer a raw color in
  `no_raw_colors` SVG attributes and `no_inline_styles` custom properties.
  Literal channels and a `var()` fallback are still reported. This removes
  findings and adds none.
- `scan_all_strings` skips plain string map keys such as
  `%{"fill-color" => 1}`, in `no_raw_colors` and `no_arbitrary_values`. Map
  values are still checked, and so are the keys of a map that reaches a merge
  function, directly or through a list, branch, pipe, variable, module
  attribute or same-module function. A merge call in a template reads a map
  from the function's variables and from assigns set anywhere in the module,
  such as `assign(socket, :tones, %{"bg-red-500" => true})` in `mount/3`, in
  `~H` and in embedded `.heex` files. A map written in the template, as in
  `<div class={cn(%{"bg-red-500" => @on})} />`, and a map a function returns,
  as in `cn(tones())` in a template, go unread: the first as before, the
  second newly. This removes findings and adds none.

## 0.2.2

- Calls through `__MODULE__` aliases, such as `__MODULE__.Client.run()`,
  no longer crash the run.
- Helpers that an embedded `.heex` template calls are read from their own
  file: findings in them are reported at the call in the template, and
  their fixes edit the helper. Before, their positions were read from the
  template, which gave wrong locations and garbled messages.
- `no_raw_colors` accepts `fill-none` and `stroke-none`, which paint nothing.

## 0.2.1

- `mix heex_lint --quiet` prints errors only, as ESLint's `--quiet` does;
  warnings still count for `--max-warnings`, so a precommit step can keep
  a warning cap without printing every existing warning.

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
- Suggestions in JSON output, `--format github` annotations, and
  `heex-lint-disable` comments. `mix heex_lint --fix` applies only the
  suggestions that generate the same CSS (spacing and radius steps, the
  variable shorthand), several per literal in one run; nearest colors, font
  size steps and spelling corrections stay suggestions, marked `exact: false`.
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
