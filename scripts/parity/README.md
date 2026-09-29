# Parity check

`run.sh` lints the same classes with @shadcn/lint's own ESLint rules and
with HeexLint, on equivalent projects, and diffs every finding:

- a React project (`fixture/`) with a `cva` Button (variants `default`,
  `destructive`, `outline`; sizes `sm`, `lg`) and a Card, and
- HeexLint's test project, with the same components as function components
  (`attr :variant, values: ...`) and the same theme.

`cases.txt` holds 552 classes: a sample of Tailwind's class list plus
colors, tokens, typos, arbitrary values, variants and markers. Each is
written on a plain element, on Button and on CardTitle, and checked with
`no-restyle`, `no-raw-colors` and `no-arbitrary-values` under two
configurations: the recommended options, and one with `deny`, contracts,
per-category messages, placeholders and exact-class allows.

Messages are compared after naming the components the same way (`<.button>`
and `<Button>`) and the component and theme files by placeholder.

```sh
scripts/parity/run.sh
```
