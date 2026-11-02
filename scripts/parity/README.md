# Parity check

`run.sh` lints the same classes with @shadcn/lint's own ESLint rules and
with HeexLint, on equivalent projects, and diffs every finding:

- a React project (`fixture/`) with a `cva` Button (variants `default`,
  `destructive`, `outline`; sizes `sm`, `lg`) and a Card, and
- HeexLint's test project, with the same components as function components
  (`attr :variant, values: ...`) and the same theme.

`cases.txt` holds 552 classes: a sample of Tailwind's class list plus
colors, tokens, typos, arbitrary values, variants and markers. Each is
written on a plain element, on Button and on CardTitle, and checked under
three configurations: `no-restyle`, `no-raw-colors` and `no-arbitrary-values`
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

The drivers take the configuration, the theme and the class list from the
`CONFIG`, `THEME` and `CASES` environment variables.

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
