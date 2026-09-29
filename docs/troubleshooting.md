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
with `attr :rest, :global`) to a design-system component.

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

## The wrong stylesheet is used as the theme

The linter picks the stylesheet that imports Tailwind with the most color
tokens, nearest the project root. Set `settings: [theme: "assets/css/app.css"]`
to choose it. In an umbrella, each app discovers its own; a configured
theme applies to every app.

## The linter cannot load the Tailwind theme

`no_unknown_classes` needs the project's Tailwind v4:

- **Node**: `tailwindcss` installed where the theme resolves it
  (`assets/node_modules` or the project root), and `node` on the `PATH`.
- **Standalone binary**: the `tailwind` hex package installs it in
  `_build/tailwind-<target>`; run `mix tailwind.install` if it is missing, or
  set `tailwind_bin`.

When neither works, the run warns once and the rule falls back to the class
grammar, which checks less: it cannot know a plugin's classes, and gives no
spelling suggestions. Fix the warning before relying on a clean result.

## A class is reported unknown but has CSS

Classes from stylesheets outside the theme's import graph are unknown to
Tailwind. Import the stylesheet from the theme, declare the class with
`@utility`, or allow it:

```elixir
no_unknown_classes: {:warning, allow: ["editor-root", "editor-*"]}
```

Classes that only serve as JavaScript or test hooks generate no CSS; that is
what the rule reports.

## Findings in a value the linter cannot read

`require_static_classes` reports class values it cannot read on components:
socket assigns in a LiveView's `render/1`, calls to functions in other
modules, text glued to a runtime value (`"bg-#{@tone}"`). Write complete
class names, move the choice into the rendering function with `assign/3`, a
local helper or a map lookup, or register a class helper in
`merge_functions`.
