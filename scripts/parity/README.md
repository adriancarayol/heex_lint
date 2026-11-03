# Parity check

`run.sh` lints the same classes with @shadcn/lint's own ESLint rules and
with HeexLint, on equivalent projects, and diffs every finding:

- a React project (`fixture/`) with a `cva` Button (variants `default`,
  `destructive`, `outline`; sizes `sm`, `lg`) and a Card, and
- HeexLint's test project, with the same components as function components
  (`attr :variant, values: ...`) and the same theme.

`cases.txt` holds 552 classes: a sample of Tailwind's class list plus
colors, tokens, typos, arbitrary values, variants and markers. Each is
written on a plain element, on Button, on CardTitle and on two wrappers, and
checked under three configurations: `no-restyle`, `no-raw-colors` and `no-arbitrary-values`
with the recommended options; the same with `deny`, contracts, per-category
messages, placeholders and exact-class allows; and `no-unknown-classes` with
`no-raw-colors`. Both linters ask the same installed Tailwind 4.3.3; the
script builds @shadcn/lint at the pinned commit so its Tailwind worker is
there, and stops if that worker falls back to the bundled grammar.

Each configuration also runs `themed_cases.txt` under each theme in `themes/`:

- `scales`: custom scales (`--radius-card`, `--shadow-soft`,
  `--border-color-line`...) and `@utility` classes,
- `radius_reset`: `--radius-*: initial` with `--radius-card`,
- `full_reset`: `--*: initial` with `--spacing` and `--color-primary`,
- `scoped_values`: `--radius-card: var(--radius)`, with `--radius` set on
  `:root` and on `.compact`.
- `explicit_imports`: `tailwindcss/theme.css` by path with `--animate-*: initial`,
  where Tailwind's animations stay motion classes.
- `workspace_package`: a package in `workspace_kit/`, linked into `node_modules`
  the way pnpm links one, whose tokens, scales and resets count as the project's.
- `prefixed`: `@import "tailwindcss" prefix(tw)`, where only `tw:` classes are
  Tailwind's. `themed_cases.txt` has `tw:` classes for it, which every other theme
  reads as an unknown variant.
- `installed_package`: a package in `installed_kit/`, copied into `node_modules`
  the way npm installs one, with both drivers' `theme_imports` naming its import.
  Its tokens and scales count, and so does the file it imports from within. Its
  own `@import "tailwindcss"` stays out.
- `installed_unnamed`: the same package by a specifier `theme_imports` does not
  name, so its tokens do not count.
- `installed_resolution`: named imports of the shapes the resolver has to read: a
  `style` condition beside a `default`, where Tailwind builds one file and both
  linters read the other, an array target, the package's `imports` map (`#tokens`),
  and `installed_bare/`, a package with no `package.json`.
- `plugin_modules`: a plugin and a config from `plugin_kit/`, copied into `node_modules`.
  Nothing in the CSS names their classes, so only Tailwind can say what they are:
  `text-body` is a font size, `text-brand` a color, and the plugin throws on `boom-bad`,
  which costs that class its answer and nothing else.
- `hostile_values`: a value that fans out to a million copies, which both linters give
  up on, the small chain beside it, which still resolves, values followed by thousands
  of spaces, and a color past the float range.

`themed_cases.txt` ends with classes written to be read badly: numbers past the float
range, modifiers and values of a thousand unclosed brackets, a thousand digits. Two such
classes stay out, because the difference is in what JavaScript's Infinity and NaN print,
and `docs/parity.md` has both: `bg-[rgb(1e300,0,0)]`, whose NaN distance makes
@shadcn/lint name the first token, and a 308-digit `p-[...px]`, whose step it prints
with an exponent.

The wrappers are `Panel`, which hands `className` to Card, `titleClassName` to
CardTitle and `footerClassName` to a plain element, and `PassedPanel`, which hands
everything to Panel through a spread. Each class goes on each of those props, and
on `PassedPanel`'s `otherClassName`, which nothing names.

The drivers take the configuration, the theme and the class list from the
`CONFIG`, `THEME` and `CASES` environment variables.

`style_cases.txt` holds `no-inline-styles` on style values written in both languages,
each with its own `allowDynamicIdentifiers`. `style_driver.ts` and `style_driver.exs`
lint them and print each case's distinct messages, not where they are, since
@shadcn/lint reports a value at the attribute that reads it. They use no theme and no
Tailwind. A string in HEEx is the object literal in JSX, a list is an object with
spreads, `%{base | a: value}` is `{ ...base, a: value }`, and `Map.get` with a default
is `??`. A case's accepted differences are in `known_gaps/configstyle-cases.txt`.

Messages are compared after naming the components the same way (`<.button>`
and `<Button>`) and the component and theme files by placeholder.

## Known gaps

`known_gaps/config<N>-<theme>.txt` lists the accepted differences of each
run, sorted bytewise, one per line: `<` for a finding only @shadcn/lint
reports, `>` for one only HeexLint reports, then class, element, rule and
message.

```sh
scripts/parity/run.sh            # fails on new differences and stale entries
scripts/parity/run.sh --update   # rewrites known_gaps/ from this run
```

The check passes only if the differences equal the known gaps, so a change
that closes a gap has to remove it from these files too. Read the diff of
`known_gaps/` before committing an update: a new `>` line is a finding
HeexLint invented, a new `<` line one it lost.

To move the pin, change `commit` and `deps` in `run.sh`; the script reinstalls
and rebuilds when they change.
