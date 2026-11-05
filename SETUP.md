# Set up HeexLint

Give your coding agent this prompt:

```text
Read https://github.com/adriancarayol/heex_lint/blob/main/SETUP.md
and set up heex_lint in this project.
```

The rest of this file is for the agent.

## Install

- Add `{:heex_lint, "~> 0.3", only: [:dev, :test], runtime: false}`
  to the `deps` of the Mix project that owns the templates (the web app, in an
  umbrella), then run `mix deps.get`.
- Run `mix heex_lint` from that project's root. With no `.heex_lint.exs`, the
  recommended rules run; that verifies the setup.

## Configure only what the project needs

Read the [configuration docs](https://github.com/adriancarayol/heex_lint#configuration)
first. Create `.heex_lint.exs` only if the defaults do not fit:

- **Theme.** The linter finds the stylesheet that imports Tailwind. Set
  `settings: [theme: "..."]` only if it picks the wrong one. If the design
  system's tokens come from an npm package, the linter does not know them until
  `settings: [theme_imports: ["^@acme/ui/"]]` names its `@import`. A theme that declares a
  token of its own reports the package's colors as undeclared until then. A theme with none
  checks no color against tokens at all, so nothing tells you.
- **Design system.** Modules under a `components/` directory are the design
  system. Add `ui:` prefixes or `component_imports:` if components live
  elsewhere.
- **Class helpers.** If the project builds classes with its own helper
  (`classes/1`, `cx/1`...), add it to `merge_functions`.
- **Tailwind.** `no_unknown_classes` asks the project's Tailwind through Node
  (`node_modules/tailwindcss`) or the standalone binary Phoenix installs in
  `_build/`. If neither is found, it uses the class grammar, which checks less,
  **with no warning**, so check that one of them is there: run `mix tailwind.install`,
  or set `tailwind_bin` if the binary lives elsewhere. A warning means Tailwind was
  found and could not answer; read it, as the rules then use the grammar too.

Do not change rule policies (`allow`, `deny`, `contracts`,
`allow_dynamic_identifiers`) or turn rules off to hide findings. Leave those
decisions to the user.

## Hand off

- Add `"heex_lint"` to the `precommit` alias (or the project's lint command).
- Add this line to `AGENTS.md`:

  ```md
  After making changes, run `mix precommit` and fix all errors.
  ```

- Run `mix heex_lint` and tell the user how many findings there are per rule,
  that no policies were written for them, and where to read about rules
  ([docs/rules.md](https://github.com/adriancarayol/heex_lint/blob/main/docs/rules.md))
  and adoption ([docs/adoption.md](https://github.com/adriancarayol/heex_lint/blob/main/docs/adoption.md)).
