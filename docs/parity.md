# Parity with @shadcn/lint

HeexLint follows [`@shadcn/lint`](https://github.com/shadcn-ui/lint) 0.2.4 and the
changes merged after it, up to commit `9231259`, with the class grammar of
[cn](https://github.com/shadcn-ui/cn) 0.4.0. This page says what was compared, maps each
part to its Phoenix counterpart, and lists where the two differ.

## What it follows

| | |
| --- | --- |
| Release | @shadcn/lint 0.2.4 |
| Commit | `9231259`, 0.2.4 plus the four changes below |
| Class grammar | cn 0.4.0 |
| Tailwind the comparison asks | 4.3.3 |

Merged after 0.2.4 and unreleased at that commit, and followed here:

| Change | Upstream |
| --- | --- |
| A contract entry the theme's Tailwind build generates, such as `prose` from a plugin, does not warn. | upstream PR 164 (commit `f0586bf`) |
| `data-*` and `aria-*` attributes such as `data-class` are not class lists. | upstream PR 162 (commit `0fd4874`) |
| `--spacing` after `--*: initial` or `--spacing-*: initial` keeps the numeric spacing scale. | upstream PR 166 (commit `9231259`) |
| A slow Tailwind worker gets a longer wait, and a fallback to the grammar warns. | upstream PR 165 (commit `1940709`) |

### Settings and options added since 0.2.0

| @shadcn/lint | HeexLint | Docs |
| --- | --- | --- |
| `settings.shadcn.themeImports` | `settings: [theme_imports: [...]]`, which also takes a `Regex` | [A design system installed as a package](./design-systems.md#a-design-system-installed-as-a-package) |
| `allowDynamicIdentifiers` on `no-inline-styles` | `allow_dynamic_identifiers` on `no_inline_styles` | [Dynamic style identifiers](./rules.md#dynamic-style-identifiers) |
| `SHADCN_LINT_TAILWIND_TIMEOUT` | `HEEX_LINT_TAILWIND_TIMEOUT` | [Tailwind classes](./how-it-works.md#tailwind-classes) |
| `{{prop}}` in `no-restyle` messages, and `{{sizes}}` on every finding | `{{prop}}`, `{{sizes}}`, and `{{where}}` for where to add a variant or size | [Your own words](./rules.md#your-own-words) |

## Verified

[`scripts/parity/run.sh`](https://github.com/adriancarayol/heex_lint/tree/main/scripts/parity)
runs @shadcn/lint's own ESLint rules at the commit above on a React project and HeexLint
on the equivalent Phoenix project, asks the same Tailwind 4.3.3 from both, and diffs every
finding. Classes go on nine kinds of element: a plain element, a Button with variants and
sizes, a CardTitle, and wrappers handing several class props on, each directly and through a
spread. The default theme runs 552 classes (a sample of Tailwind's class list plus colors,
tokens, typos, arbitrary values, variants and markers), and 12 other themes run 196 classes
written for what they change.

The result of the last run, with every run `ok` and no accepted differences, is
`parity ok against 9231259: 0 known gaps`:

| Configuration | Runs | Findings upstream | Differences |
| --- | --- | --- | --- |
| `no-restyle` and `no-arbitrary-values` with `allow: ["layout"]`, `no-raw-colors` | 13 themes | 28,869 | 0 |
| `deny`, contracts, per-category messages, placeholders with fallbacks, group and exact-class allows | 13 themes | 26,310 | 0 |
| `no-unknown-classes` with `no-raw-colors`, asking Tailwind (suggestions and typo ownership) | 13 themes | 16,128 | 0 |
| `no-inline-styles` with `allowDynamicIdentifiers`, on 97 style values written in both languages, comparing each value's distinct messages | 1 | 70 | 0 |
| The class grammar: group and category of each name in Tailwind's class list, with every modifier Tailwind lists and behind `hover:`, and every variant in front of a sample | 1 | 457,699 names | 0 |

That is 71,377 findings and 457,699 classified names. `known_gaps/` is empty, so there is no
accepted difference to explain. The themes cover custom scales, namespace resets, scoped
values, imports by path, a linked workspace package, `prefix(tw)`, an installed package named
and not named by `theme_imports`, the shapes of package resolution, a plugin and a config,
and hostile values; [`scripts/parity/README.md`](https://github.com/adriancarayol/heex_lint/blob/main/scripts/parity/README.md)
has each one.

Both linters ask the same installed Tailwind, so `no-raw-colors` hands a typo of another
utility (`text-smal`) to `no-unknown-classes` the same way.

Compared with @shadcn/lint's own functions at this commit by one-off scripts, which are not
in the repository:

| What | Compared | Differ |
| --- | --- | --- |
| Validators, class normalizing, opacity modifiers, `splitArbitrary`, colors, lengths, `resolveVariables`, `parseDeclarations`, `parseUtilities` and `replaceClass`, on generated and hostile input | 253,408 | 11, all `1e999px`, in the row below on the float range |
| Edit distance | 30,000 pairs | 0 |

`run.sh` puts classes on elements and compares messages, so it does not reach variable chains,
map lookups, `assign/3`, merge-function calls, positions, `--fix`, the standalone binary or a
component from `deps/`. Tests here pin those. One-off differentials also compared generated variable
graphs, wrapper graphs, `style` values and stylesheet shapes with @shadcn/lint when each was ported,
and 26 shapes of merge-function call in a template, on 9 classes under two sets of rules, whose 193
distinct messages were the same once `<.button>` reads `<Button>`. Positions and `--fix`
were not compared, and @shadcn/lint has no standalone binary. No CI job runs `run.sh`; it runs by
hand.

### What each upstream release changed

Every change to the package since 0.2.0 that is not a test or a release chore, except the four
above.

| Upstream | Change | Here |
| --- | --- | --- |
| 0.2.1: upstream PR 52 (commit `ee93910`) | A project's theme scales, the way cn 0.4.0 merges them | The same: `HeexLint.Grammar.ThemeScales`. |
| 0.2.1: upstream PR 68 (commit `0e91da3`) | Tailwind beside the stylesheet that imports it | The same. |
| 0.2.1: upstream PR 76 (commit `ab7658a`) | `cva` and `tv` classes keyed by a computed name | Already so: `variant_functions` read the value of a computed key. |
| 0.2.1: upstream PR 77 (commit `bbe3a2a`) | Unprefixed classes left to `no-unknown-classes` under a prefix | The same. |
| 0.2.1: upstream PR 78 (commit `60836cc`) | `@config` and `@plugin` load as Tailwind loads them | The same, through `@tailwindcss/node` when it is installed. |
| 0.2.1: upstream PR 81 (commit `334ded6`) | Dotted `mergeFunctions` match method calls | Already so: `merge_functions: ["Helpers.classes"]` matches that call. |
| 0.2.1: upstream PR 82 (commit `32b37e4`) | `fill-none` and `stroke-none` | The same, since 0.2.2. |
| 0.2.1: upstream PR 86 (commit `207c442`) | Font sizes from an `@config` or `@plugin` are typography | The same, through Node and the standalone binary. |
| 0.2.1: upstream PR 79, 83, 84, 85 and 80 (commits `8455c18`, `a38ee04`, `557e75e`, `b16b8cf`, `8abc06b`) | `aliases.ui`, `cva` factories, `render` props, `package.json` imports for a ui alias, Svelte shorthand | No counterpart in HEEx. |
| 0.2.2: upstream PR 87 (commit `44d6cbf`) | `themeImports`, and no package file named as the place to add a variant | `theme_imports`, and `to <.button>` for a component from `deps/`. |
| 0.2.2: upstream PR 88 (commit `1561353`) | `deny` reports `white` and `black` | The same. |
| 0.2.2: upstream PR 90 (commit `5ef03bf`) | `@utility` classified by what its body sets | The same. |
| 0.2.2: upstream PR 91 (commit `dde45eb`) | `{{sizes}}` on every finding | The same. |
| 0.2.2: upstream PR 92 (commit `868955e`) | `allowDynamicIdentifiers` | `allow_dynamic_identifiers`. |
| 0.2.2: upstream PR 95 (commit `ea6b078`) | A received `labelClass` counts as forwarded | Already so for a received `*_class`. |
| 0.2.2: upstream PR 115 (commit `f15b93d`) | Scales from aliased imports, `themeImports` packages, and after a nested `@keyframes` | The last two. Aliased imports are not followed: see below. |
| 0.2.2: upstream PR 94 (commit `9a55f6d`) | An auto-imported Vue component | No counterpart in HEEx. |
| 0.2.3: upstream PR 107 (commit `f1c81bd`) | A nested namespace, `<UI.Button.Root>` | Already so for `<AppWeb.UI.Button.root>`. |
| 0.2.3: upstream PR 121 (commit `24a73ee`) | Variables from `:root` and `@theme` over a scoped selector | The same. |
| 0.2.3: upstream PR 122 (commit `cf6487f`) | `divide-*` reads `--border-color-*` | The same. |
| 0.2.3: upstream PR 123 (commit `c0d164b`) | `scanAllStrings` skips plain object keys | `scan_all_strings` skips plain map keys. See the row on class map keys below. |
| 0.2.3: upstream PR 124 (commit `118a109`) | A color function over one theme variable | The same. |
| 0.2.3: upstream PR 125 (commit `1d31b7f`) | A wrapper's other class props, each against its own target | The same for `title_class`. |
| 0.2.3: upstream PR 126 (commit `cbc8d4d`) | tw-animate-css classes are motion | The same. |
| 0.2.3: upstream PR 105 (commit `808970e`) | `stop-color`, `flood-color`, `lighting-color` in Svelte and Vue | HEEx writes these names, and they are read. |
| 0.2.3: upstream PR 104 and 106 (commits `acee889`, `355eb51`) | Svelte `$derived`, and a custom property passed to a Svelte component | No counterpart in HEEx. |
| 0.2.4: upstream PR 145 and 161 (commits `0c06f22`, `5e5eacf`) | A const read once per site, and a chain past 64 links is dynamic | The same for classes, and a stopped read is also remembered: see below. |
| 0.2.4: upstream PR 149 (commit `6e1a943`) | An `@import` with no `;` in one pass | The same. |
| 0.2.4: upstream PR 151 (commit `420aeda`) | Limits on what Tailwind is asked, and a class that throws costs only itself | The same. |
| 0.2.4: upstream PR 152 (commit `ab2050f`) | Hostile class tokens in linear time | The same. |
| 0.2.4: upstream PR 153 (commit `f3e26c5`) | A variable past 100,000 characters is unresolved | The same, counted in UTF-16 units as JavaScript does. |
| 0.2.4: upstream PR 154 and 155 (commits `afd9dc8`, `ffd23a9`) | `exports` conditions 32 levels deep, targets stay inside the package, and no stray UNC path | The same. |
| 0.2.4: upstream PR 146, 147, 148 and 150 (commits `3cbaf51`, `da8344d`, `2120be8`, `7bf3502`) | JavaScript import and export lists, barrels, `tsconfig` values | No counterpart in HEEx. |

## The same

| @shadcn/lint | HeexLint |
| --- | --- |
| `no-restyle`, `no-raw-colors`, `no-arbitrary-values`, `no-inline-styles`, `no-unknown-classes`, `require-static-classes` | The same rules, snake_cased, with the same semantics and message text. |
| Class grammar from `cn` 0.4.0, with the theme's scales applied as `mergeConfigs` does | Vendored config and a port of its trie and validators; checked to classify Tailwind 4.3's full class list (457,699 names with its modifiers and variants) identically. `HeexLint.Grammar.ThemeScales` ports `themeScalesOf`, and a theme that declares scales gets its own trie. |
| Categories and `GROUP_CATEGORY` | `HeexLint.Grammar.Categories`, the same table and arbitrary-property rules. |
| `allow`, `deny`, `contracts`, entry validation, a class the theme's build generates being known, config errors on line 1 | `HeexLint.Policy`, a port of `contracts.ts`. |
| A font size from an `@config` or `@plugin`, read from the theme's own Tailwind | The same, through Node and from the standalone binary's output, with no Node started until such a class needs it. |
| Messages, `{{placeholder\|fallback}}`, `note`, typo warnings, 500-char limit | `HeexLint.Messages`. |
| Theme reading: `@theme` tokens, resets, scoped namespaces, dark blocks, `--spacing`, radius/text scales, `@utility`, class selectors, `prefix(tw)`, discovery | `HeexLint.Theme`; checked against the reference on sample themes. |
| OKLab colors, CSS named colors, `calc()` lengths, edit distance | `HeexLint.Grammar.Colors`, `Lengths`, `Similar`; checked against the reference. |
| Tailwind oracle (`candidatesToCss`, suggestions, variant typos, the 10,000-character and 64-variant limits, a class that throws costing only itself, Tailwind found beside an imported stylesheet) | `priv/tailwind_oracle.mjs`, the same logic. Plugins load through `@tailwindcss/node` when it is installed, so CommonJS plugins (Phoenix's heroicons) load too. It also ends with the linter and refuses a theme whose `@import`s reach more than 10,000 stylesheets, which @shadcn/lint at `9231259` lets run until its wait is over. |
| A worker past 60 seconds on a first answer and 30 on a later one is restarted once; `SHADCN_LINT_TAILWIND_TIMEOUT` | The same waits through Node, and the process is killed; 60 seconds for each question through the standalone binary; `HEEX_LINT_TAILWIND_TIMEOUT` for all of them. Here a stylesheet past the wait uses the grammar for the rest of the run, where @shadcn/lint asks again, since a run ends and an editor session does not. Another stylesheet gets a new process, and two failures turn it off, as there. |
| Suggestions that rewrite one class inside its literal | The same, plus `mix heex_lint --fix` for single suggestions. |
| `--max-warnings`, file overrides, `eslint-disable` comments | `--max-warnings`, `overrides`, `heex-lint-disable` comments. |
| `settings.shadcn` (`ui`, `componentImports`, `ignoreImports`, `themeImports`, `mergeFunctions`, `variantFunctions`, `note`) | `settings` (`ui`, `component_imports`, `ignore_imports`, `theme_imports`, `merge_functions`, `variant_functions`, `note`). `theme_imports` also takes a `Regex`. |

## Adapted for Phoenix

| @shadcn/lint | HeexLint |
| --- | --- |
| JSX, Vue and Svelte templates | HEEx: `~H` sigils and `.heex` files, through LiveView's tokenizer. |
| `className` | `class` and other class attributes (`input_class`...). |
| Components from `components.json` / `components/ui`, plus `ui` and `componentImports` | Function components in modules under `components/`, plus `ui` module prefixes and `component_imports`. |
| Import resolution, re-exports, barrels | `import`, `alias` and `use MyAppWeb, :html` expansion. |
| Components from packages ("use components you don't own") | Components from `deps/` (SaladUI, PetalComponents...), recognized through `component_imports`. |
| Variants from `cva`/`tv` and string-union props | `attr :variant, values: [...]` and `attr :size, values: [...]`. |
| Wrappers forwarding `className`, render props | Components forwarding `@class` or global attributes (`{@rest}`). Slots belong to their component. |
| A wrapper's other class props, such as `headerClassName`, each on its own path; `{{prop}}` | The same for `title_class`, and `{{prop}}` is `class` or the attribute; on a slot it is `class`. `class` is the main prop, not `className`, which is an assign of its own here. Global attributes stop carrying a prop once `attr` declares it, as destructuring does. Wrappers that render each other differ: each prop is followed along its own route until it repeats, so it reaches the components it can reach, where @shadcn/lint at `9231259` stops at the first component or file being read and can find nothing. A wrapper from `deps/` counts as a wrapper here, where a package never does there. |
| Same-file `const`/`let`, a route of 64, each read once per site | Function-body variables, `assign/3` in the rendering function, module attributes, same-module helpers and map lookups, with the same limit. A read that stopped is also remembered with its route, so a branching chain past the limit or ending in a cycle finishes here; @shadcn/lint at `9231259` does not finish those. Bindings that all read each other get 4,096 reads per site here, and a read past that counts as unreadable. A `style` has no limit in either, whole (`style={v}`) or in a hole (like a value of `{"--tone": v}`), as `check` and `carriesRawColor` keep no route. A cycle there ends the read here, reported as dynamic when the `style` is whole, and overflows the stack in @shadcn/lint at `9231259`. |
| An object is mutable, so a second name for one (`const t = s`), and so a lookup through it, is dynamic. A computed member (`variants[v]`) is dynamic, and destructuring reads the literal | A value cannot change, so `t = s` and a lookup on `t` are read. A computed or missing key on a variable or a module attribute (`Map.fetch!(@variants, @variant)` in a function) reads every entry, since that is how a variant table is written: its classes are checked and no dynamic finding is given. A key that is a literal reads as a map does: its last write, with `1`, `1.0` and `-1` as keys of their own. JavaScript has no plain `-1` key, so `@t[-1]` reads that entry here, where `t[-1]` is computed there. In a hole a table reads every entry whatever the key, as `carriesRawColor` does, so `"--x: #{t.a}"` reports a raw color in any entry of `t`, there and here. On a table assigned with `assign/3`, as in a template's `@variants[@v]`, it is dynamic, as there. A pattern is not read: `%{a: s} = %{a: "color: red"}` is dynamic, and exempt under `s`. |
| Class object keys, `cn({ "bg-pink-500": on })`, are read as classes | A map's or keyword list's keys are read only under `scan_all_strings`, when a map reaches a merge function from Elixir code. By default, `cn(%{"bg-pink-500" => on})` has no finding here and one there. Under the option, a map written in a template, `<div class={cn(%{"bg-pink-500" => @on})} />`, still has none here and one there. A Phoenix class list has no such form: it is written `@on && "bg-pink-500"`, which is read. |
| `scanAllStrings` reads every `Literal` with a hyphen, in code and markup, but for plain object keys and what a class site on a tag has read. A template literal is not a `Literal` | `scan_all_strings` reads the same in Elixir code, quoted attribute values and a template's `{...}` and `<%= ... %>`. An interpolated string is not a literal, and neither is a sigil such as `~w(...)`. A class site reads more here, so `"bg-pink-500 " <> @a`, `%{a: "bg-pink-500"}[@v]`, `String.trim("bg-pink-500")` and `Enum.join(["p-1", "bg-pink-500"], " ")` on a component's `class` are left to its contract here, where @shadcn/lint at `9231259` reports the same code in JavaScript. Map keys skip the contract, so `t = %{"bg-pink-500" => on}` then `<.button class={cn(t)}>` has a finding here and none there. A `@doc` string is read here, where the same text is a comment there. |
| A tag inside an expression, `{on ? <b className="bg-pink-500" /> : null}`, is read | A `~H` inside a template's `{...}` is not read by any rule. |
| Every call to a merge function in a file is checked, on no component, unless a class site or another such call has read it | The same, in Elixir code and in a template's `{...}`, `<%= ... %>`, `:if` and `:for`. A class site reads more here, so a call inside `Enum.join`, `String.trim`, `<>` or a lookup on a map is that site's: `<.button class={Enum.join([cn("bg-pink-500")], " ")}>` under a contract allowing the class has no finding here, and `[cn("bg-pink-500")].join(" ")` has one there. An EEx tag a block splits does not parse alone, so `<%= Enum.map(cn("bg-pink-500"), fn x -> %>` and `<% end, cn("bg-pink-500")) %>` have no finding here, and the `.map` has one there. A variable is followed only in a function's body: `x = "bg-pink-500"` then `cn(x)` in a script, a module's body, a function an `if` defines or a template's `fn` has no finding here and one there. A call in a heredoc or `~s` hole on a class attribute is not that attribute's, so a contract does not reach it, where a multi-line template literal is the site's there. |
| `cva` and `tv` read `base`, `slots`, `class`, `className`, `variants` and a compound variant's `class` | `variant_functions` read every value of the map, so `tv(%{default_variants: %{size: "xx-large"}})` is reported as a class here and not there. |
| Received `className` prop | A function component's received `class`; socket assigns in a LiveView `render/1` are not received props. |
| `allowDynamicIdentifiers`: `floatingStyles`, `styles.popper`. A name is exempt, with whatever it reads, unless its value is an object literal | `allow_dynamic_identifiers`: `@floating_styles`, `floating_styles`, `assigns.floating_styles`, `styles.popper`, with the same rule. A list is not a spread in every case: an allowed name in a list, as in `style={[@a || @b]}`, is exempt here and dynamic there, and `style={[styles.popper]}` with a written entry is checked here and gives nothing there. A style is text here, so what still gets checked is a string, `<>`, a sigil or a list, as well as a map, which stays dynamic. In Vue and Svelte, @shadcn/lint at `9231259` exempts a string bound to an allowed name, as only an object literal counts there. `styles[:popper]` and `Map.get(styles, :popper)` are that path too, where a computed member is no name in @shadcn/lint. `Map.get(styles, :popper, other)` is `styles.popper ?? other`: `other` is a value of its own. `Floating.styles` names a call, which has no name in @shadcn/lint, since Elixir reaches a library through one. So `styles.popper()` under `styles.popper` is exempt here and dynamic there. A value assigned in `mount/3` or a helper has no equivalent in @shadcn/lint: it cannot be read here, so a name exempts it. A variable spread in, as in `{...{ style: s }}`, is uncertain in @shadcn/lint at `9231259`, since an object put in another can change. A value cannot here, so `{%{style: s}}` is read like `style={s}`. An entry that cannot match is a configuration error here, and is ignored there. |
| `{{component}}` as `Button` | `.button`, the way the tag is written. Contract patterns match the function name: `^button$`. |
| Monorepos: a theme per package | Umbrellas: a theme (and Tailwind) per app. |
| The theme read resolves a package `@import` with `resolveFile`: `exports` by `import`, `default`, `require`, `node`, `types` and then the other conditions as written, array targets, the `imports` map, then the package's own files and `src/`, with or without a `package.json`. Tailwind's build prefers the `style` condition, so a kit's tokens can come from another file than it builds | The same. A bare `@import "kit"` that finds no file that way then follows the package's `style` field, as Tailwind does, so that kit's `@utility` rules count and `theme_imports` can name it. It follows `main` as well, and Tailwind's build there follows both. Those two fields are the only additions. |
| The same read follows tsconfig `paths` and the `@/`, `~/` and `$lib` aliases, and reads a `package.json` with comments or trailing commas | Not followed: these are JavaScript bundler conventions, so the build here cannot resolve such an import either, and `no_unknown_classes` warns and uses the grammar. A `package.json` must be strict JSON; one that is not counts as absent, and so does one with `1e999` or a lone surrogate, which `JSON.parse` accepts and Elixir's decoder does not. |
| Past the float range a length is `Infinity`, and a color computes on through `Infinity` and `NaN` | A length stops at `1e307`, and a color at one value near no other, since Elixir raises where JavaScript goes on. So what follows from such a value differs, and only on values no real theme has. `calc(1e999px - 1e999px + 12px)` is `12px` here and `NaN` there, so `rounded-[calc(1e999px-1e999px+12px)]` can be offered a step as the same value. `--radius-lg: calc(1e200 * 1e200)` stays a step of `1e307` here and is removed there, `--spacing: 1e999px` gives `p-[13px]` the generic message here and `p-0` there, `rounded-[1e999px]` is the same value as a step `--radius-x: 1e999px` here and not there, and a step past `1e21` prints its digits rather than an exponent. A theme color past the range is near no other here, where its `NaN` makes it the nearest there: with `--color-bad: rgb(1e300 0 0)`, `bg-[#123456]` finds no close color here and `bg-bad` there, and `text-[#eeeeee]` gets `text-secondary` here and both there. |
| Every `@utility` body is read to its close, so bodies left open or nested in each other are quadratic | The same, up to 16 passes over the file. Past that a body sets nothing a category can be read from. Real bodies do not overlap, so they never get there. |
| `\s` in the CSS read is JavaScript's, so a non-breaking space separates properties in an `@utility` body | Elixir's `\s` has no non-breaking space, so a property right after one, `@utility x {<NBSP>color: red; }`, is not read. |
| An `@import "tailwindcss"` reads Tailwind's entry as CSS, and its `dist/lib.mjs` with it, so words in that JavaScript such as `x`, `p`, `w`, `rem` and `node:path` count as classes your CSS declares | That file is not read. A class of those names is one the grammar does not recognize, here under `no_restyle`. Upstream's answer is an accident of what its read reaches, so it is not copied. |
| Tailwind through Node only | Node, the standalone Tailwind binary Phoenix installs in `_build/`, then the grammar. The binary gives no suggestions, so `text-smal` goes to `no_raw_colors` there and to `no_unknown_classes` through Node. It reads a built stylesheet, so a `.name` anywhere in the build counts: one only another rule mentions, such as `qux` beside `[&_.qux]:flex`, `png` beside `bg-[url(/a.png)]`, or `com` from the build's banner comment, passes there and not through Node. A class that makes a plugin throw takes the whole stylesheet to the grammar when the stylesheet's own `@source` reaches it, since Tailwind then cannot build it. |
| No shared config; enable each rule | A recommended set when `rules` is not given. |

## HeexLint additions

- `no_unknown_variables`: classes such as `bg-(--surfce)` that read a CSS
  variable the theme never defines. @shadcn/lint lets variable references
  pass without checking them.
- `heex-lint-disable-file` alongside `-line` and `-next-line`.
