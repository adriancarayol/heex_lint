# Troubleshooting

## A component is not being checked

`no_restyle` and `require_static_classes` check design-system components
only. Check that:

- The component's module is under a `components/` directory, or named by
  `ui` or `component_imports`, and not excluded by `ignore_imports`.
- The tag resolves to it: `<.button>` through the template's module, its
  `import`s, or what its `use MyAppWeb, :html` imports; `<Mod.button>`
  through the module's aliases. A component from a dependency needs
  `component_imports`, such as `["^SaladUI\\."]`.
- The file is in `inputs` and an override has not turned the rule off.

A wrapper component outside the design system is checked when it forwards
its `class` (`class={[..., @class]}`) or its global attributes (`{@rest}`
with `attr :rest, :global`) to a design-system component. Each class prop
counts on its own: `<.panel title_class="...">` is checked only if `panel` hands
`title_class` to one, and then against that one's contract.

## The theme has no tokens

Tokens are `--color-*` declarations inside `@theme` blocks. Variables in
`:root` alone are CSS variables, used through `bg-(--surface)`, not
Tailwind colors. To make them tokens, map them:

```css
@theme inline {
  --color-surface: var(--surface);
}
```

Without tokens, `no_raw_colors` still reports palette colors, but cannot
suggest replacements or check undeclared names.

## A design system's colors read as undeclared

Stylesheets under `node_modules` contribute no tokens. If your design system is
installed as a package, name its import with
[`theme_imports`](./design-systems.md#a-design-system-installed-as-a-package):
`settings: [theme_imports: ["^@acme/ui/"]]`. The pattern reads the `@import` as
your stylesheet writes it, not the path it resolves to. If it is named and its colors
are still undeclared, the import may reach another file than Tailwind builds: see
[which file a package import reads](./design-systems.md#which-file-a-package-import-reads).

## The wrong stylesheet is used as the theme

The linter picks the stylesheet that imports Tailwind with the most color
tokens, nearest the project root. Set `settings: [theme: "assets/css/app.css"]`
to choose it. In an umbrella, each app discovers its own; a configured
theme applies to every app.

## The linter cannot load the Tailwind theme

`no_unknown_classes` needs the project's Tailwind v4:

- **Node**: `tailwindcss` installed where the theme resolves it
  (`assets/node_modules` or the project root), or beside a stylesheet the theme
  imports that imports Tailwind, and `node` on the `PATH`.
- **Standalone binary**: the `tailwind` hex package installs it in
  `_build/tailwind-<target>`; run `mix tailwind.install` if it is missing, or
  set `tailwind_bin`.

**With neither installed, there is no warning.** Every rule that asks Tailwind uses
the class grammar, which checks less: it cannot know a plugin's classes, and gives no
spelling suggestions. A plugin's class is then reported as one Tailwind does not know.
If that happens, look for one of the two above.

A warning means Tailwind was found and could not answer: the theme does not build, or
`node` exited with no binary to fall back on. That stylesheet then uses the grammar too.
Fix the warning before relying on a clean result. Through the standalone binary, a class
that makes a plugin throw takes the stylesheet there when the build reaches the class,
through its own `@source` or through Tailwind's automatic detection from its directory, since
Tailwind cannot build it at all; the project's real build fails the same way.

If the warning says the Tailwind process did not answer within so many seconds, the
theme's build took longer than the wait: 60 seconds for a stylesheet's first answer through Node and 30 for later
ones, and 60 for each question through the standalone binary. A plugin stuck in a loop or
a cycle of `@import`s does this. On a machine that is only slow, raise the wait with
`HEEX_LINT_TAILWIND_TIMEOUT`, in milliseconds. It replaces all of those waits.

## A file is not being linted

- It has to match `inputs`, which defaults to `lib/**/*.{ex,exs,heex}`.
- Any path with a directory named `deps` in it is skipped, since that is where Mix puts
  dependencies. That includes `lib/my_app_web/components/deps/button.ex`, and a whole
  project checked out under a directory named `deps`.

## A run stops with an error

- **`File.Error` with `:eisdir`.** An `inputs` glob matched a directory, such as
  `apps/*/lib` or `lib/*`. Write a glob of files, `apps/*/lib/**/*.{ex,exs,heex}`, or the
  directory itself, `lib`, which is expanded.
- **`literal_alloc: Cannot allocate ... bytes`.** The VM ran out of room for the project it
  keeps while linting, at about 1 GB. Generated code gets there first: an ordinary project
  needs about 20 MB of source, more or less by how it is written. Take the generated files
  out of `inputs`.
- **An exception from a class or value** is a bug: please report it. One shape that still
  stops a run is a number past the VM's integer limit, which is about 1 MB of hexadecimal,
  1.4 million octal digits or 4.2 million binary ones, such as `p-0xfff...`. In
  `allow_dynamic_identifiers`, so does an improper list
  or a string that is not valid UTF-8.

## A class is reported unknown but has CSS

Classes from stylesheets outside the theme's import graph are unknown to
Tailwind. Import the stylesheet from the theme, declare the class with
`@utility`, or allow it:

```elixir
no_unknown_classes: {:warning, allow: ["editor-root", "editor-*"]}
```

Classes that only serve as JavaScript or test hooks generate no CSS; that is
what the rule reports.

Under `@import "tailwindcss" prefix(tw)`, a class generates CSS only with the
prefix first: `tw:hover:flex`, not `flex` or `hover:tw:flex`.

A class longer than 10,000 characters, with more than 64 variants, or that makes a
plugin throw is not judged by `no_unknown_classes`. The other rules still read it.

## Findings in a value the linter cannot read

`require_static_classes` reports class values it cannot read on components:
socket assigns in a LiveView's `render/1`, calls to functions in other
modules, text glued to a runtime value (`"bg-#{@tone}"`), and a computed key on an
assigned table (`@tones[@tone]`). Write complete class names, move the choice into the
rendering function with a local helper, a map lookup on a variable or `assign/3` of the
class it picks, as in `assign(assigns, :tone_class, %{a: "p-1"}[assigns.tone])`, or
register a class helper in `merge_functions`.
