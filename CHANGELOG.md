# Changelog

## Unreleased

- A class no longer ends a run. `p-1e999`, `z-1e999`, a class with a 400-digit number and
  `rounded-[1e999px]` raised an exception where JavaScript reads Infinity, and so did a
  class past about 32 KB with a suggestion, which was compiled into a regex. **In runs
  that used to crash, this adds the findings they never got to.**
- A stylesheet with a byte that is not UTF-8, such as a comment saved as Latin-1, ended
  the run, wherever it sat in the project. It is read like any other. An `.ex` or `.heex`
  file with one ended it too, and now counts as a file that cannot be parsed.
- A `<%` with no `%>`, such as `class="p-1<%x"`, ended the run, in a `.heex` file or a
  `~H`. That file now counts as one that cannot be parsed, and the others are linted.
  **In runs that used to crash, this adds the findings they never got to.**
- A theme value past the float range, such as `--radius-x: 1e999px` or
  `--color-x: oklab(1e200 0 0)`, no longer ends the run. Such a length is further than
  any step and such a color is near no other, which is what @shadcn/lint's Infinity comes
  to.
- `--fix` and suggestions no longer corrupt a class whose replacement starts with a digit:
  `flex 2xl:p-[12px]` became `flexxl:p-3`, and is now `flex 2xl:p-3`.
- A double-quoted string in an expression is read in one pass. It was cubic:
  `class={"..."}` of 2,000 characters took 14 seconds and of 4,000 took 110. No findings
  change.
- Class tokens of thousands of unclosed brackets or digits, such as `bg-red-500/[/[/[`,
  `[a:a:a:` or `text-[calc(calc(`, are read in one pass, as in @shadcn/lint. So are long
  style values and `@theme` blocks of thousands of declarations. No findings change,
  except that as in @shadcn/lint a bracket or paren in an opacity modifier holds no
  other. **This changes findings on such a class only:** `bg-red-500/[a[b]` is an
  undeclared color rather than a palette class, and `bg-primary/[a[b]`, which had no
  finding, is now reported as one.
- A theme variable stops resolving once its value would grow past 100,000 UTF-16 units,
  as in @shadcn/lint, and is unresolved like one with no value. A kilobyte of `var()` naming
  `var()` 16 times over six levels took 15 seconds to load, and takes milliseconds.
- A theme reads each variable once, where a long `var()` fallback was read again at every
  reference. A 300 KB stylesheet that named one 20,000 times took 3 seconds per token to
  load, and with 500 tokens takes 50 milliseconds. No findings change, except that bytes
  that are not UTF-8 cut apart by a `var()` count as Node reads them, which only matters
  right at the budget.
- A theme value with more than about 4,500 spaces inside it was dropped without a word,
  by a limit in the regex engine, and is now read, as in @shadcn/lint. **This can add
  findings** where that value was what a token or step named.
- An `@import` starting with two slashes or backslashes reads nothing outside the project,
  as in @shadcn/lint: on Windows, looking at such a path sends the user's credentials to
  the host it names. **On any system this removes what such an import contributed**, such
  as `//home/me/theme.css`, which read as `/home/me/theme.css`.
- `@utility` bodies left open or nested in each other read in at most 16 passes over the
  file, which @shadcn/lint does not limit. Past that a body sets nothing a category can be
  read from, as an empty one does.
- A contract entry the theme's Tailwind build generates, such as a plugin's `prose`, is
  known like any other class, as in @shadcn/lint, and no longer warns. One a slip away
  from a category, such as `spacin`, is no configuration error either when the build
  generates it. A build that fails, or no Tailwind to ask, still warns. Node starts for
  this only when an entry is unknown to the grammar and the theme, and with that a
  theme that cannot be built can warn in a run of `no_restyle` or `no_arbitrary_values`
  alone.
- A theme that loads an `@config` or `@plugin` has its own Tailwind say which `text-*`
  classes are font sizes, as in @shadcn/lint, through Node and through the standalone
  binary. Node starts for this only on such a theme and for a `text-*` class the grammar
  reads as a color, and so also for `no_restyle` and `no_arbitrary_values`, which never
  started it. **This removes findings:** `no_raw_colors` no longer calls `text-body`
  from a `fontSize` an undeclared color. **It also adds findings:** `deny` naming
  typography now reaches it, and `allow: ["color"]` no longer covers it. The standalone
  binary takes one build for the classes a run's files and contract entries name, and
  a rule in the theme's own CSS, such as `.card .text-primary { font-size: 1rem }`, does
  not make a class a font size there, as it does not through Node.
- The Tailwind process cannot outlive the linter or stall it. The Node process runs
  Tailwind on a worker thread and ends within moments of its stdin closing, whatever a
  plugin is doing. Each question has a deadline, 60 seconds for a stylesheet's first
  answer and 30 for later ones, and `HEEX_LINT_TAILWIND_TIMEOUT`, in milliseconds,
  replaces both. Past it the process is killed, with whatever it started, and the
  standalone binary is treated the same. That stylesheet then uses the class grammar
  for the rest of the run, with a warning, and two failures turn Tailwind off for the
  run. Where a slow Tailwind or a dead oracle used to end the run with an exit, every
  rule now falls back to the grammar and says so. **This changes findings only for
  those stylesheets:** the grammar accepts less of what a plugin generates, so
  `no_unknown_classes` can report a plugin's class there.
- A theme whose `@import`s form a cycle with fan-out no longer runs until the machine
  is out of files. Through Node, past 10,000 stylesheets the build is refused at once,
  with a warning, and every rule uses the grammar. The standalone binary is stopped at
  the deadline.
- As in @shadcn/lint, a class longer than 10,000 characters or with more than 64
  variants is not judged, and a class that makes a plugin throw costs only its own
  answer, through Node and through the standalone binary, where one used to take the
  whole theme down to the grammar. **This removes findings** on such classes, and
  **adds some:** the other classes of a theme with such a plugin are judged by Tailwind
  again rather than the grammar, as `no_unknown_classes` and `no_raw_colors` do.
- As in @shadcn/lint, Tailwind is also looked for beside a stylesheet the theme imports
  that imports Tailwind, for a workspace or an umbrella where only a UI package depends
  on it, including one only a package's `style` condition leads to. So Node now starts
  for a question whenever a `node_modules` is in reach, and gives way to the standalone
  binary or the grammar when none holds Tailwind, or when `node` exits before its first
  answer, as a version manager's shim with no version set does. What such a `node` prints
  still reaches the terminal. **This adds findings** where that
  theme used the grammar or the standalone binary: `no_unknown_classes` now asks that
  Tailwind and offers suggestions.
- Through the standalone binary, a class with an open bracket or quote, such as the typo
  `text-[foo`, no longer swallows the classes after it. **This removes findings:**
  `class="text-[foo flex"` reported `flex` as unknown, as it never did through Node.
- `@import`s in the Node build now resolve the way @shadcn/lint's build does, which
  also follows a package's `main` and `src/` where `@tailwindcss/node` did not. **This
  adds findings:** a theme that warned and used the grammar over one of these imports
  now gets Tailwind's answers. `NODE_PATH` no longer counts for a stylesheet. A plugin's
  `console.log` no longer corrupts the answers either.
- A lookup on a map update reads `%{base | a: value}` as @shadcn/lint reads
  `{ ...base, a: value }`, in a variable or an assign. A key it writes has that value,
  any other key is its base's, and a key the base cannot answer is unreadable, as is a
  computed one. **This adds findings:** these lookups reported nothing. With
  `t = %{assigns.base | a: Lib.compute()}`, `style={t.a}` and `style={t.b}` are dynamic
  and `<.button class={t.a}>` reaches `require_static_classes`. With `a: "color: red"`,
  `style={t.a}` reports `color`, whatever `allow_dynamic_identifiers` names, and
  `a: "bg-pink-500"` reaches `no_raw_colors` and the other class rules. A raw color the
  map writes is also seen in a style hole, as in `"--tone: #{t.a}"`.
- In a template, `assigns.name`, `assigns[:name]`, `Map.get(assigns, :name)` and
  `Map.fetch!(assigns, :name)` read what the rendering function assigns, as `@name`
  does, and a lookup on them or on `@name` reads a table assigned there, as in
  `@styles.popper`. **This adds findings:** `assign(assigns, :s, "color: red")` with
  `style={assigns.s}` reports `color`, and a `class` read the same way reaches
  `no_raw_colors` and the other class rules. The dynamic or `require_static_classes`
  finding those values had goes away.
- The default of `Map.get` and `Keyword.get` is read when the map cannot be, as it
  already was when the map could. **This adds findings:**
  `style={Map.get(@styles, :popper, "color: red")}` reports `color` as well as the
  dynamic map, and a `class` default reaches `no_raw_colors` and the other class rules.
- New `allow_dynamic_identifiers` option on `no_inline_styles`, as in @shadcn/lint: style
  values a library computes, by the name the code reads them under, such as
  `@floating_styles`, `floating_styles`, `assigns.floating_styles`, `styles.popper` or
  `Floating.styles`. A name matches the read spelled the same way, in a `style`
  attribute or a map spread onto a tag. A value written out where the name is bound is
  still checked; any other value is exempt with whatever it goes on to read. Anything
  but a list of such names is a configuration error. **This adds no findings:** it only
  removes the ones you name, and nothing changes without the option.
- The theme read resolves a package `@import` as @shadcn/lint's does. `exports` reads
  the conditions `import`, `default`, `require`, `node`, `types` and then the others as
  written, where it read `style` and then `default`. It also reads array targets, the
  package's `imports` map (`#tokens`), `src/`, and a package with no `package.json`, and
  it refuses a target that leaves the package. A package's `style` and `main` fields
  now count only when a bare import finds no other file. **This changes findings, with
  or without `theme_imports`:** a package's tokens, `@utility` names and classes can
  come from another file than before. That file can differ from the one Tailwind builds,
  since Tailwind prefers `style`. A `{"style": "./theme.css", "import": "./index.js"}`
  entry now reads the script and contributes nothing, which **adds findings**: name the
  stylesheet by its own path instead. A named package of a shape it could not read
  before **loses findings**: its colors were reported as undeclared.
- New `theme_imports` setting, as in @shadcn/lint: regexes on `@import` specifiers
  whose stylesheets count as your own though they resolve under `node_modules`, for
  a design system installed as a package. Stylesheets the package imports from within
  itself count too, and its own `@import "tailwindcss"` stays out, so the palette is
  still reported. An invalid pattern warns once and is ignored. Nothing changes
  without the setting. **With it, findings change:** the package's colors stop being
  reported as undeclared, and its scales, values and resets now apply, which **adds
  findings** too: a `--radius-*: initial` in the package makes `rounded-lg`
  unrecognized. Its tokens also count when choosing which stylesheet is the theme.
  A stylesheet under `deps/` already counted as your own, and still does.
- With the standalone Tailwind binary, a class is known only when its whole selector
  is in the build. **This adds findings, with or without a prefix:** `fle` beside
  `flex`, or `hover` beside `hover:flex`, read as known because a longer selector
  started with them. The Node path always asked for the class itself.
- Under `@import "tailwindcss" prefix(tw)`, only `tw:flex` is a Tailwind class, as in
  @shadcn/lint. `no_raw_colors` leaves an unprefixed class alone, where it called
  `text-muted` an undeclared color, and judges `tw:text-muted` as before. **This
  removes those findings and adds others:** `no_unknown_classes` now reports an
  unprefixed color class as unknown, as it already did `flex`. That includes classes
  naming a declared token, such as `text-primary`, which had no finding at all. A
  project with a prefix that runs only one of the two rules sees only one half. The
  prefix is read from your own stylesheets and not from an installed package, and from
  the stylesheet Tailwind builds when `theme` names a partial. With the standalone
  binary, `tw:hovr:flex` now reads as a misspelled variant. **This adds findings:**
  `tw:hovr:bg-primary` was dropped without a word.
- A wrapper's class props each follow their own path, as in @shadcn/lint: a
  `title_class` handed to `<.card_title>` is judged against `card_title`, not
  against what `class` reaches, and `{{prop}}` names the attribute in `no_restyle`
  messages (`forwards title_class to <.card_title>`). The text for `class` is
  unchanged. Every class rule reads the same target. **This adds findings:** a class
  prop is checked against its own component's contract; chains of wrappers resolve
  at any depth, where a chain past a few hops was unchecked; a tag spreading
  `{%{class: @class}}` forwards it; and a readable map's other class keys, as in
  `{%{title_class: "p-4"}}`, are read as attributes on any element. **It also
  removes findings** on classes a wrapper does not hand to that component:
  `title_class` on a wrapper that forwards only `class`, `class` on one that
  forwards only another assign such as `@title_class` or `@merged_class`, and `class`
  declared with `attr` beside a `{@rest}` that no longer carries it. When a prop lands
  on nested tags, the inner one now decides, and spacing advice also offers the
  component behind a parent written as a wrapper or with its module, both as in
  @shadcn/lint.
- A chain of variables, attributes, functions and lookups to a class is followed
  for 64 bindings instead of 4, and the next one is unreadable, as in
  @shadcn/lint. **This adds findings:** a class more than four links away is now
  checked by every rule, where it was dropped without a word, and a chain past 64
  is reported by `require_static_classes` at the read that goes past the limit. A
  `style` has no limit, also as in @shadcn/lint. **This adds findings too:**
  `no_inline_styles` checks a `style` value any number of links away, and reports
  a raw color any number of links from a hole, as in `"--tone: #{v}"`. A long chain
  alone never makes a `style` dynamic. A binding is read once per site, so a
  generated chain of `if on, do: a, else: a` stays linear, also past the limit or
  ending in a cycle. A default that reads its own prop ends there: a class says
  nothing more about it, and a whole `style` is reported as dynamic.
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
