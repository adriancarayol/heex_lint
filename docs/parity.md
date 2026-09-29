# Parity with @shadcn/lint

HeexLint follows [`@shadcn/lint`](https://github.com/shadcn-ui/lint) 0.2.0.
This page maps each part to its Phoenix counterpart.

## The same

| @shadcn/lint | HeexLint |
| --- | --- |
| `no-restyle`, `no-raw-colors`, `no-arbitrary-values`, `no-inline-styles`, `no-unknown-classes`, `require-static-classes` | The same rules, snake_cased, with the same semantics and message text. |
| Class grammar from `cn` 0.3.2 | Vendored config and a port of its trie and validators; checked to classify Tailwind 4.3's full class list (46k variants) identically. |
| Categories and `GROUP_CATEGORY` | `HeexLint.Grammar.Categories`, the same table and arbitrary-property rules. |
| `allow`, `deny`, `contracts`, entry validation, config errors on line 1 | `HeexLint.Policy`, a port of `contracts.ts`. |
| Messages, `{{placeholder\|fallback}}`, `note`, typo warnings, 500-char limit | `HeexLint.Messages`. |
| Theme reading: `@theme` tokens, resets, scoped namespaces, dark blocks, `--spacing`, radius/text scales, `@utility`, class selectors, discovery | `HeexLint.Theme`; checked against the reference on sample themes. |
| OKLab colors, CSS named colors, `calc()` lengths, edit distance | `HeexLint.Grammar.Colors`, `Lengths`, `Similar`; checked against the reference. |
| Tailwind oracle (`candidatesToCss`, suggestions, variant typos) | `priv/tailwind_oracle.mjs`, the same logic; loads through `@tailwindcss/node` so CommonJS plugins (Phoenix's heroicons) load too. |
| Suggestions that rewrite one class inside its literal | The same, plus `mix heex_lint --fix` for single suggestions. |
| `--max-warnings`, file overrides, `eslint-disable` comments | `--max-warnings`, `overrides`, `heex-lint-disable` comments. |
| `settings.shadcn` (`ui`, `componentImports`, `ignoreImports`, `mergeFunctions`, `variantFunctions`, `note`) | `settings` (`ui`, `component_imports`, `ignore_imports`, `merge_functions`, `variant_functions`, `note`). |

## Adapted for Phoenix

| @shadcn/lint | HeexLint |
| --- | --- |
| JSX, Vue and Svelte templates | HEEx: `~H` sigils and `.heex` files, through LiveView's tokenizer. |
| `className` | `class` and other class attributes (`input_class`...). |
| Components from `components.json` / `components/ui`, plus `ui` and `componentImports` | Function components in modules under `components/`, plus `ui` module prefixes and `component_imports`. |
| Import resolution, re-exports, barrels | `import`, `alias` and `use MyAppWeb, :html` expansion. |
| Variants from `cva`/`tv` and string-union props | `attr :variant, values: [...]` and `attr :size, values: [...]`. |
| Wrappers forwarding `className`, render props | Components forwarding `@class` or global attributes (`{@rest}`). Slots belong to their component. |
| Same-file `const`/`let`, one hop | Function-body variables, `assign/3` in the rendering function, module attributes, same-module helpers and map lookups. |
| Received `className` prop | A function component's received `class`; socket assigns in a LiveView `render/1` are not received props. |
| `{{component}}` as `Button` | `.button`, the way the tag is written. Contract patterns match the function name: `^button$`. |
| Tailwind through Node only | Node, the standalone Tailwind binary Phoenix installs in `_build/`, then the grammar. |
| No shared config; enable each rule | A recommended set when `rules` is not given. |

## HeexLint additions

- `no_unknown_variables`: classes such as `bg-(--surfce)` that read a CSS
  variable the theme never defines. @shadcn/lint lets variable references
  pass without checking them.
- `heex-lint-disable-file` alongside `-line` and `-next-line`.
