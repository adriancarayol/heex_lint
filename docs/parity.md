# Parity with @shadcn/lint

HeexLint follows [`@shadcn/lint`](https://github.com/shadcn-ui/lint) 0.2.0.
This page maps each part to its Phoenix counterpart.

## Verified

[`scripts/parity/run.sh`](https://github.com/adriancarayol/heex_lint/tree/main/scripts/parity) lints 552 classes (a sample of
Tailwind's class list plus colors, tokens, typos, arbitrary values, variants
and markers) on a plain element, a Button with variants and sizes, a CardTitle,
and wrappers handing several class props on, with @shadcn/lint's own ESLint rules
on a React project and with HeexLint on the equivalent Phoenix project, and diffs
every finding:

| Configuration | Findings | Differences |
| --- | --- | --- |
| `no-restyle` and `no-arbitrary-values` with `allow: ["layout"]`, `no-raw-colors` | 5379 | 0 |
| `deny`, contracts, per-category messages, placeholders with fallbacks, group and exact-class allows | 5176 | 0 |
| `no-unknown-classes` with `no-raw-colors`, asking Tailwind 4.3.3 (suggestions and typo ownership) | 3267 | 0 |

Both linters ask the same installed Tailwind, so `no-raw-colors` hands a
typo of another utility (`text-smal`) to `no-unknown-classes` the same way.

The grammar (Tailwind 4.3's full class list, 46k classes with variants),
colors, lengths, edit distance and theme reading are checked against the
reference the same way.

## The same

| @shadcn/lint | HeexLint |
| --- | --- |
| `no-restyle`, `no-raw-colors`, `no-arbitrary-values`, `no-inline-styles`, `no-unknown-classes`, `require-static-classes` | The same rules, snake_cased, with the same semantics and message text. |
| Class grammar from `cn` 0.4.0, with the theme's scales applied as `mergeConfigs` does | Vendored config and a port of its trie and validators; checked to classify Tailwind 4.3's full class list (46k variants) identically. `HeexLint.Grammar.ThemeScales` ports `themeScalesOf`, and a theme that declares scales gets its own trie. |
| Categories and `GROUP_CATEGORY` | `HeexLint.Grammar.Categories`, the same table and arbitrary-property rules. |
| `allow`, `deny`, `contracts`, entry validation, config errors on line 1 | `HeexLint.Policy`, a port of `contracts.ts`. |
| Messages, `{{placeholder\|fallback}}`, `note`, typo warnings, 500-char limit | `HeexLint.Messages`. |
| Theme reading: `@theme` tokens, resets, scoped namespaces, dark blocks, `--spacing`, radius/text scales, `@utility`, class selectors, `prefix(tw)`, discovery | `HeexLint.Theme`; checked against the reference on sample themes. |
| OKLab colors, CSS named colors, `calc()` lengths, edit distance | `HeexLint.Grammar.Colors`, `Lengths`, `Similar`; checked against the reference. |
| Tailwind oracle (`candidatesToCss`, suggestions, variant typos) | `priv/tailwind_oracle.mjs`, the same logic; loads through `@tailwindcss/node` so CommonJS plugins (Phoenix's heroicons) load too. |
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
| A wrapper's other class props, such as `headerClassName`, each on its own path; `{{prop}}` | The same for `title_class`, and `{{prop}}` is `class` or the attribute. `class` is the main prop, not `className`, which is an assign of its own here. Global attributes stop carrying a prop once `attr` declares it, as destructuring does. Wrappers that render each other differ: each prop is followed along its own route until it repeats, so it reaches the components it can reach, where @shadcn/lint at `9231259` stops at the first component or file being read and can find nothing. |
| Same-file `const`/`let`, a route of 64, each read once per site | Function-body variables, `assign/3` in the rendering function, module attributes, same-module helpers and map lookups, the same limit and the same reads. A read that stopped is also remembered with its route, so a branching chain past the limit or ending in a cycle finishes here; @shadcn/lint at `9231259` does not finish those. A `style` has no limit in either, whole (`style={v}`) or in a hole (like a value of `{"--tone": v}`), as `check` and `carriesRawColor` keep no route. A cycle there ends the read here, reported as dynamic when the `style` is whole, and overflows the stack in @shadcn/lint at `9231259`. |
| Received `className` prop | A function component's received `class`; socket assigns in a LiveView `render/1` are not received props. |
| `allowDynamicIdentifiers`: `floatingStyles`, `styles.popper`. A name is exempt, with whatever it reads, unless its value is an object literal | `allow_dynamic_identifiers`: `@floating_styles`, `floating_styles`, `assigns.floating_styles`, `styles.popper`, with the same rule. A style is text here, so what still gets checked is a string, `<>`, a sigil or a list, as well as a map, which stays dynamic. In Vue and Svelte, @shadcn/lint at `9231259` exempts a string bound to an allowed name, as only an object literal counts there. `styles[:popper]` and `Map.get(styles, :popper)` are that path too, where a computed member is no name in @shadcn/lint. `Floating.styles` names a call, which has no name in @shadcn/lint, since Elixir reaches a library through one. An entry that cannot match is a configuration error here, and is ignored there. |
| `{{component}}` as `Button` | `.button`, the way the tag is written. Contract patterns match the function name: `^button$`. |
| Monorepos: a theme per package | Umbrellas: a theme (and Tailwind) per app. |
| The theme read resolves a package `@import` with `resolveFile`: `exports` by `import`, `default`, `require`, `node`, `types` and then the other conditions as written, array targets, the `imports` map, then the package's own files and `src/`, with or without a `package.json`. Tailwind's build prefers the `style` condition, so a kit's tokens can come from another file than it builds | The same. A bare `@import "kit"` that finds no file that way then follows the package's `style` field, as Tailwind does, so that kit's `@utility` rules count and `theme_imports` can name it. It follows `main` as well, which `@tailwindcss/node` does not: `no_unknown_classes` then warns and uses the grammar. Those two fields are the only additions. |
| The same read follows tsconfig `paths` and the `@/`, `~/` and `$lib` aliases, and reads a `package.json` with comments or trailing commas | Not followed: these are JavaScript bundler conventions, and Tailwind's build cannot resolve such an import either, so `no_unknown_classes` warns and uses the grammar. A `package.json` must be strict JSON; one that is not counts as absent. |
| Tailwind through Node only | Node, the standalone Tailwind binary Phoenix installs in `_build/`, then the grammar. |
| No shared config; enable each rule | A recommended set when `rules` is not given. |

## HeexLint additions

- `no_unknown_variables`: classes such as `bg-(--surfce)` that read a CSS
  variable the theme never defines. @shadcn/lint lets variable references
  pass without checking them.
- `heex-lint-disable-file` alongside `-line` and `-next-line`.
