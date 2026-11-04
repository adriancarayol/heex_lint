# Changelog

## Unreleased

HeexLint now follows [@shadcn/lint](https://github.com/shadcn-ui/lint) 0.2.4 and the changes
merged after it, up to commit `9231259`, with the class grammar of
[cn](https://github.com/shadcn-ui/cn) 0.4.0. [docs/parity.md](docs/parity.md) has what was
compared and where the two differ.

**Upgrading can report findings your code did not have before.** Most come from reading
further into values and themes. Start with [New findings](#new-findings); to adopt them
gradually, set the affected rules to `:warning` and use `mix heex_lint --max-warnings`.

### New settings and options

- `theme_imports` setting: regexes on `@import` specifiers whose stylesheets count as your
  own though they resolve under `node_modules`, for [a design system installed as a
  package](docs/design-systems.md#a-design-system-installed-as-a-package). Stylesheets the
  package imports from within itself count too, and its own `@import "tailwindcss"` stays
  out, so Tailwind's palette is still reported. An invalid pattern warns once and is
  ignored. It is a setting only.
- `allow_dynamic_identifiers` option on `no_inline_styles`: style values a library computes,
  by the name the code reads them under, such as `@floating_styles`, `floating_styles`,
  `assigns.floating_styles`, `styles.popper` or `Floating.styles`. A name matches the read
  spelled the same way, in a `style` attribute or a map spread onto a tag. A value written
  out where the name is bound is still checked; any other value is exempt with whatever it
  goes on to read. Anything but a list of such names is a configuration error, as is the
  option in a contract. See [dynamic style
  identifiers](docs/rules.md#dynamic-style-identifiers).
- `HEEX_LINT_TAILWIND_TIMEOUT`, in milliseconds, replaces how long the linter waits for
  Tailwind. See [Crashes, hangs and slowness](#crashes-hangs-and-slowness).
- `no_restyle` messages have `{{prop}}`, the class attribute the class was written in, and
  `{{where}}`, where to add a variant or size. `{{sizes}}` now holds the size names on every
  finding, and is empty when the component has none, where it printed the placeholder on a
  color or layout finding.

### New findings

Each of these reports something that passed before.

**Whatever your configuration.**

- **Merge-function calls outside a class value.** Every call to `cn`, `Tails.classes`,
  `TwMerge.merge`, `Twix.tw` or a function in `merge_functions` or `variant_functions` is now
  checked, wherever the file has it. In a template that is `title={cn("bg-pink-500")}`,
  `<div>{cn("bg-pink-500")}</div>`, `{render_slot(@a, cn("bg-pink-500"))}`, `<%= %>`, `<% %>`,
  `:if`, `:for`, the condition of `class={if cn("bg-pink-500"), do: "p-1"}`, and a call nothing
  follows, as in `class={foo(cn("bg-pink-500"))}`. In Elixir code it is a module attribute, a
  default argument, a module's body, a function's `rescue` and the like, and a script. A piped
  value is read as well, as in `"bg-pink-500" |> cn()`. Such a class is on no component, so a contract does not exempt it,
  and `no_restyle` and `require_static_classes` say nothing about it. A call a class attribute
  reads stays that attribute's.
- **Classes further away.** A class is followed through 64 bindings instead of 4: variables,
  attributes, functions and lookups. A class more than four links away now reaches every
  rule. Past 64, or at an unknown call more than four links away, `require_static_classes`
  reports it on a component.
- **Styles further away.** A `style` has no limit. `no_inline_styles` checks a value any
  number of links away, and reports a raw color any number of links from a hole, as in
  `"--tone: #{v}"`. A long chain alone never makes a `style` dynamic. A `style` default that
  reads its own prop is reported as dynamic.
- **Variables read directly.** `<.button class={v}>` is read where the function binds `v`,
  with reports and fixes there. Its classes were dropped. `@name` in that value is a module
  attribute, not an assign.
- **Two variables of one name.** With `c` in two functions and one calling the other, the
  classes behind it are now read. It read as a cycle, whose false dynamic finding goes away.
- **`assigns.name` in a template.** `assigns.name`, `assigns[:name]`, `Map.get(assigns,
  :name)` and `Map.fetch!(assigns, :name)` read what the rendering function assigns, as
  `@name` does, and a lookup on them or on `@name` reads a table assigned there, as in
  `@styles.popper`. A computed or missing key on such a table, as in `@styles[@tone]`, reads
  no entry and stays dynamic. `assign(assigns, :s, "color: red")` with `style={assigns.s}` reports
  `color`, and a `class` read this way reaches `no_raw_colors` and the other class rules.
  The dynamic or `require_static_classes` finding such a value had usually goes away; one
  appears where the value assigned cannot be read, as in `assign(assigns, :class,
  Lib.merge(assigns.class))`.
- **Map updates.** A lookup on `%{base | a: value}` reads as `{ ...base, a: value }` does: a
  key it writes has that value, any other key is its base's, and a key the base cannot
  answer, or a computed one, is unreadable. These lookups reported nothing. With `t =
  %{assigns.base | a: Lib.compute()}`, `style={t.a}` and `style={t.b}` are dynamic and
  `<.button class={t.a}>` reaches `require_static_classes`. A raw color the map writes is
  also seen in a hole.
- **Lookup defaults.** The default of `Map.get` and `Keyword.get` is read when the map
  cannot be: `style={Map.get(@styles, :popper, "color: red")}` reports `color` as well as
  the dynamic map, and a `class` default reaches the class rules.
- **Wrappers.** Each class prop of a wrapper is judged against the component it reaches: a
  `title_class` handed to `<.card_title>` against `card_title`'s contract, not what `class`
  reaches. Chains of wrappers resolve at any depth, where one past a few hops was unchecked.
  A tag spreading `{%{class: @class}}` forwards it, and a readable map's other class keys,
  as in `{%{title_class: "p-4"}}`, are read as attributes on any element.
- **SVG color attributes in braces.** `fill={"#ec4899"}` and `stroke={"red"}` are read as
  `fill="#ec4899"` and `stroke="red"` always were. Nothing else in braces is.
- **Wrappers reading a class prop through `Map`.** A wrapper with `class={Map.get(assigns,
  :class)}` or `Map.fetch!(assigns, :class)` is followed like `assigns[:class]`, so its class
  prop is judged against the component it reaches, as `<.w class="bg-pink-500">` now is.
- **Theme resets.** The grammar reads the scales your `@theme` declares. `--radius-*:
  initial` makes `rounded-lg` unrecognized until the theme declares it again, and `--*:
  initial` does this to every scale but colors and fonts, though `--spacing` set after it
  keeps the numeric spacing scale. A `shadow-lg` or `text-lg` after
  such a reset reads as a color, so `no_raw_colors` reports it as undeclared. After
  `--animate-*: initial`, `animate-spin` is unrecognized under `@import "tailwindcss"`, and
  stays a motion class when the theme imports `tailwindcss/theme.css` or
  `tailwindcss/index.css` by path.
- **Workspace packages.** A package linked into `node_modules`, as pnpm and npm workspaces
  do, counts as your own: its colors become the tokens `no_raw_colors` checks against, its
  `--radius-*: initial` makes `rounded-lg` unrecognized, and its `--radius-card` makes
  `rounded-card` a shape class that `no_restyle` reports.
- **Package imports.** The theme read resolves a package `@import` as @shadcn/lint's does:
  `exports` by `import`, `default`, `require`, `node`, `types` and then the others as
  written, where it read `style` and then `default`. A package's tokens, `@utility` names
  and classes can therefore come from another file than before, which can differ from the
  file Tailwind builds. A `{"style": "./theme.css", "import": "./index.js"}` entry now reads
  the script, so a named package's colors read as undeclared: import the stylesheet by its
  own path instead.
- **Tailwind found in more places.** Tailwind is also looked for beside a stylesheet the
  theme imports that imports Tailwind, for a workspace or umbrella where only a UI package
  depends on it, and the Node build follows a package's `main` and `src/`. A theme that used
  the grammar or the standalone binary there now gets Tailwind's answers, so
  `no_unknown_classes` reports what Tailwind cannot generate and offers suggestions.
- **Themes with a plugin that throws.** A class that makes a plugin throw costs only its own
  answer, so the other classes of that theme are judged by Tailwind again rather than the
  grammar. Through the standalone binary this holds unless the build reaches that class,
  through the stylesheet's own `@source` or Tailwind's automatic detection from its
  directory, since Tailwind then cannot build the theme at all.
- **Standalone binary, names that only start a selector.** `fle` beside `flex`, or `hover`
  beside `hover:flex`, read as known before, with or without a prefix, and no longer do. A
  `.name` anywhere else in the build still counts, such as `png` beside `bg-[url(/a.png)]`.
- **A stylesheet past its deadline** uses the grammar for the rest of the run, with a
  warning. The grammar accepts less of what a plugin generates, so `no_unknown_classes` can
  report a plugin's class there.
- **A commented-out `@utility`** no longer counts as declared, the way Tailwind treats it.
- **A theme value with more than about 4,500 spaces inside it** is read, where a limit in
  the regex engine dropped it without a word, and can name a token or step.
- **A malformed modifier.** `bg-primary/[a[b]`, which had no finding, is reported, because
  as in @shadcn/lint a bracket or paren in an opacity modifier holds no other.
- **Runs that used to crash** now get the findings they never got to. See [Crashes, hangs
  and slowness](#crashes-hangs-and-slowness).

**Only where your configuration asks for it.**

- `deny` reports `white` and `black` when it matches them, as in `deny: ["*-white",
  "*-black"]`, or a category or group that covers them, as in `deny: ["color"]`, and
  suggests the nearest theme tokens. Without such a `deny` they still pass, and a theme
  declaring `--color-white` still owns it.
- `allow` and `deny` now reach classes by what they are:
  - A declared scale class by its category: `deny: ["shape"]` reaches `rounded-card`.
  - An `@utility` by the properties its body sets: `deny: ["typography"]` reaches `@utility
    heading-2xs { font-size: 0.75rem }`, and `@utility text-md-regular { font-size: 1rem }`,
    which the grammar read as a color, no longer passes `allow: ["color"]`.
  - With `@import "tw-animate-css"`, `animate-in`, `fade-in`, `slide-in-from-top-1` and the
    rest, and any `--tw-enter-*`, `--tw-exit-*` or `--tw-animation-*` arbitrary property, as
    motion.
  - On a theme that loads an `@config` or `@plugin`, a font size from it as typography:
    `deny: ["typography"]` reaches `text-body`, and `allow: ["color"]` no longer covers it.
- Under `@import "tailwindcss" prefix(tw)`, `no_unknown_classes` reports an unprefixed color
  class as unknown, as it already did `flex`, including one naming a declared token such as
  `text-primary`, which had no finding at all. With the standalone binary,
  `tw:hovr:bg-primary` reads as a misspelled variant, where it was dropped without a word.
- With `theme_imports`, the package's scales, values and resets apply: a `--radius-*:
  initial` in it makes `rounded-lg` unrecognized.
- `scan_all_strings` now reads the string literals in template expressions, not only quoted
  attribute values and Elixir code, so `no_raw_colors` and `no_arbitrary_values` report more
  under it: `title={"bg-pink-500"}`, `data-class={if @on, do: "bg-pink-500"}`,
  `<div>{"bg-pink-500"}</div>`, `<%= "bg-pink-500" %>` and `:if={@tone == "bg-pink-500"}`.

- **Table keys and holes.** A literal key reads as a map does: its last write, and `1`, `1.0`,
  `-1` and `false` as keys of their own. In a hole, as in `"--x: #{t.a}"`, a table reads every
  entry, as in @shadcn/lint, so a raw color in another entry of `t` is reported there.
- Under `scan_all_strings`, a map read through an assigned table in a template, as in
  `cn(@t.a)`, or by a merge call in a module attribute or a default argument, is reported.

### Findings that go away

- `data-*` and `aria-*` attributes such as `data-class` are no longer read as class lists,
  and a component passing `@class` only through `data-class` no longer counts as forwarding
  it. `data_class` and `metadata-class` still are. Under `scan_all_strings` their values are
  still reported, like any other string.
- `no_raw_colors` accepts `--border-color-*` tokens for `divide-*`, the way Tailwind falls
  back from `--divide-color-*`, and offers them for a mistyped `divide-*` class.
- A color function whose channels are one theme variable, such as
  `oklch(var(--primary-oklch) / 0.2)`, is no longer a raw color in SVG attributes and custom
  properties. Literal channels and a `var()` fallback still are.
- `scan_all_strings` skips plain string map keys such as `%{"fill-color" => 1}`, in
  `no_raw_colors` and `no_arbitrary_values`. Map values are still checked, and so are the
  keys of a map that reaches a merge function, directly or through a list, branch, pipe,
  variable, table lookup, same-module function or an assign set anywhere in the module, or
  a module attribute, in or out of a function's body.
  **Some real class keys go unread with them:** a map a function returns, as in `cn(tones())`
  in a template, a map piped through another call first, as in `%{...} |> Map.put(...) |> cn()`,
  a map reaching `cn(@tones)` as a component's prop or a `:for` variable, and a default
  argument read as a variable, as in `def a(tones \\ %{...}), do: cn(tones)`. A map written
  in a template, as in `<div class={cn(%{"bg-red-500" => @on})} />`, stays unread as it was,
  where @shadcn/lint reports it.
- `scan_all_strings` leaves a class a tag's class site reads to that site, so a component's
  contract decides it: `<.button class="bg-pink-500">` under a contract allowing that class
  is no longer reported. A string bound in code and read there is still reported.
- `scan_all_strings` skips a string with no hyphen, such as a `"[padding:13px]"` outside a
  class site. A class site still reads it.
- Classes a wrapper does not hand to that component: `title_class` on a wrapper that
  forwards only `class`, `class` on one that forwards only another assign such as
  `@title_class` or `@merged_class`, and `class` declared with `attr` beside a `{@rest}`
  that no longer carries it.
- `no_restyle` passes what your contract's categories now cover: `tap-target`, with
  `min-height` in its `@utility`, passes `allow: ["layout"]`; `rounded-card` passes `allow:
  ["shape"]`; `animate-in` passes `allow: ["motion"]`.
- `--text-primary` beside `--color-primary` makes `text-primary` a font size, which
  `no_raw_colors` does not check. On a theme with an `@config` or `@plugin`, so does a
  `fontSize` of `body` for `text-body`. **This also adds a finding:** a contract about
  typography now reaches the class, so `<.button class="text-primary">` under `allow:
  ["color"]` is reported. A rule in the theme's own CSS, such as `.card .text-primary {
  font-size: 1rem }`, does not make a class a font size.
- Under `prefix(tw)`, `no_raw_colors` leaves an unprefixed class alone, where it called
  `text-muted` an undeclared color. A project that runs only one of `no_raw_colors` and
  `no_unknown_classes` sees only one half of this change. The prefix is read from your own
  stylesheets and not from an installed package.
- With `theme_imports`, the package's colors stop being reported as undeclared, and its
  tokens count when choosing which stylesheet is the theme. A named package of a shape that
  could not be read before, such as an array target, the `imports` map or no `package.json`,
  gets the same. A target that leaves the package is refused, and a package's `style` and
  `main` fields count only when a bare import finds no other file.
- A class longer than 10,000 characters, with more than 64 variants, or that makes a plugin
  throw is not judged by `no_unknown_classes`.
- Through the standalone binary, a class with an open bracket or quote no longer swallows
  the ones after it: `class="text-[foo flex"` reported `flex` as unknown.
- An `@import` starting with two slashes or backslashes reads nothing outside the project,
  on any system: on Windows, looking at such a path sends your credentials to the host it
  names. What `//home/me/theme.css` used to contribute is gone.
- A theme variable stops resolving once its value would grow past 100,000 UTF-16 units, and
  is unresolved like one with no value.
- `@utility` bodies that hold another, nested or left open, are read in at most 16 passes
  over the file. Past that such a body sets nothing a category can be read from, as an empty
  one does. A body with none inside it is always read.
- `allow_dynamic_identifiers` only removes findings, for the names you list.

### Findings that change

- Theme variables resolve from `:root`, `html`, `:host` and `@theme` over scoped selectors
  such as `.compact`, across imported files too. With `--radius-card: var(--radius)`, `:root
  { --radius: 8px }` and `.compact { --radius: 4px }`, `no_arbitrary_values` called
  `rounded-[4px]` an exact match for `rounded-card`, and `--fix` wrote that class. It now
  writes `rounded-sm`. Scoped values still apply to variables nothing else sets.
- When several scale steps have the same value, `no_arbitrary_values` and `--fix` name the
  one declared first, Tailwind's own before the theme's, instead of the first by name.
- `--fix` and suggestions no longer corrupt a class whose replacement starts with a digit:
  `flex 2xl:p-[12px]` became `flexxl:p-3`, and is now `flex 2xl:p-3`.
- `no_restyle` reports a class your theme declares under its category rather than as
  unclassified: `rounded-card` is shape, and `--tracking-*`, `--leading-*`, `--blur-*`,
  `--ease-*`, `--aspect-*`, `--spacing-*`, `--perspective-*`, `--breakpoint-*`,
  `--container-*`, `--font-weight-*`, `--animate-*` and the shadow and text namespaces work
  the same way. An `@utility` is classified by its body: a body setting several things takes
  the first appearance, so `display` plus `color` is color, and exact names win over
  prefixes such as `@utility tab-*`. A body-less `@utility` and a plain selector stay
  unclassified. After a reset, `shadow-lg` is color rather than effects.
- `no_restyle` no longer sends anyone to add a variant or size in `deps/`. A finding on a
  component from a dependency says "Add a new variant to <.button>" instead of naming the
  file, and `{{file}}` is empty there. Messages for your own components are unchanged.
- When a prop lands on nested tags, the inner one now decides the contract, and spacing
  advice also offers the component behind a parent written as a wrapper or with its module.
- `bg-red-500/[a[b]` is an undeclared color rather than a palette class.
- With the standalone binary, `tw:hovr:flex` is an unknown variant rather than an unknown
  class.
- A stylesheet reached by two import paths is read once, at the first, as is one spelled
  two ways on a case-insensitive disk. Reading it again put
  its declarations over the ones read between the two imports, so this can change the
  category `no_restyle` reports and the values the theme resolves. The limit of 65
  stylesheets now counts the whole import tree rather than one chain, and a bare
  `@import "tailwindcss"` takes one of them, as in @shadcn/lint. Packages contribute
  the `--animate-*` names of their `@theme`, and `NODE_PATH` no longer counts for a
  stylesheet.
- A stylesheet that starts with a byte order mark reads like one without it, as in
  @shadcn/lint. Its leading `:root` was read as a scoped selector, so an earlier value won.
- A contract entry the theme's Tailwind build generates, such as a plugin's `prose`, is
  known like any other class and no longer warns, and `spacin`, a slip away from a category,
  is no configuration error when the build generates it. An entry nothing knows still warns.
  Asking makes a theme that cannot be built able to warn in a run of `no_restyle` or
  `no_arbitrary_values` alone.

### Crashes, hangs and slowness

- **The Tailwind process cannot outlive the linter or stall it.** The Node process runs
  Tailwind on a worker thread and ends within moments of its stdin closing, whatever a
  plugin is doing, and the standalone binary is stopped the same way. The linter waits 60
  seconds for a stylesheet's first answer through Node and 30 for later ones, and 60 for
  each question through the standalone binary; `HEEX_LINT_TAILWIND_TIMEOUT` replaces all of
  them. Past that the process is killed, with whatever it started but a child a plugin
  detaches, which leaves the process group. That stylesheet uses the
  grammar for the rest of the run, with a warning, and two failures turn Tailwind off for
  the run. Where a slow Tailwind or a dead oracle used to end the run with an exit, every
  rule now falls back to the grammar and says so.
- **A theme whose `@import`s form a cycle with fan-out** no longer runs until the machine is
  out of files. Through Node, past 10,000 stylesheets the build is refused at once, with a
  warning. The standalone binary is stopped at the deadline, and without Node it can use
  several gigabytes by then.
- **Node when it is needed.** Node starts only when a rule has a question for Tailwind and a
  `node_modules` is in reach, and gives way to the standalone binary or the grammar when
  none holds Tailwind or when `node` exits before its first answer, as a version manager's
  shim with no version set does. What such a `node` prints still reaches the terminal. A
  plugin's `console.log` no longer corrupts the answers.
- **Runs that ended with an exception** and now finish: a number past the float range in a
  class, such as `p-1e999`, `z-1e999` or a 400-digit class, or in a theme value, such as
  `--radius-x: 1e999px` or `--color-x: oklab(1e200 0 0)`; a class past about 32 KB with a
  suggestion; a stylesheet with a byte that is not UTF-8; an `.ex` or `.heex` file with such
  a byte or a `<%` with no `%>`, which now counts as a file that cannot be parsed while the
  others are linted. [Troubleshooting](docs/troubleshooting.md#a-run-stops-with-an-error)
  lists what can still end a run.
- **Runs that never finished** and now do: a lookup on a table that names itself (`t = t`,
  `@t @t`, `t = %{a: t[:a]}`), a default that reads its own prop, and generated chains of
  `if on, do: a, else: a`, also past the limit or ending in a cycle.
- **Slow input read in one pass:** a double-quoted string in an expression (`class={"..."}`
  of 4,000 characters took 110 seconds); class tokens of thousands of unclosed brackets or
  digits, such as `bg-red-500/[/[/[`; long style values, custom properties included, and
  `@theme` blocks of thousands of declarations; a stylesheet of 5 MB or more with no `;` after
  its imports, as in @shadcn/lint; `var()` naming `var()` many times over, which took 15
  seconds on a kilobyte;
  a long `var()` fallback named again and again, which is now read once per variable; a
  repeated `@import "tailwindcss"`, which read Tailwind's stylesheets each time. No
  findings change, except as listed above.
- The standalone binary takes one build for the classes a run's files and contract entries
  name, rather than one per `text-*` class, on a theme with an `@config` or `@plugin`.
- `no_raw_colors` no longer runs a standalone Tailwind build for each undeclared color. Only
  Node's answers can change that finding, so through the binary such a class costs no build.

- Two linters at once no longer share a build directory, where one could read the other's
  answer, and a VM that exits during a build leaves no directory behind.
- A plugin writing to stdout with no newline no longer costs its stylesheet the answer, and a
  question waits for any number ahead of it while they are being answered.
- A spelling suggestion costs the length of two long names, not its square in time and memory.
  One line of many string literals under `scan_all_strings` costs its length. A number too
  large for the VM, such as a 1 MB hex digit run, reads as infinity and no longer ends a run.

### API changes

The Project API's shapes may change before 1.0, as [docs/api.md](docs/api.md) says. For
anyone calling it:

- `Theme.load/2` and `Theme.discover/2` take the `theme_imports` patterns, and
  `Project.wrapped/3` takes the class attribute, both with a default.
- `Theme.scale/2` returns an ordered list of `{name, px}` rather than a map.
- `Tailwind.start/1` replaces `start_link/1`: the oracle is unlinked and monitors its owner.
- A custom rule's file context has a new `merge_functions` key, and sites and collector
  results have new fields.

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
