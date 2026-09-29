# API reference

## Running the linter

```elixir
config = HeexLint.Config.load(".heex_lint.exs")
result = HeexLint.run(config)
# or lint some files, reading the whole project for resolution:
result = HeexLint.run(config, ["lib/my_app_web/live"], root: "/path/to/project")
```

`result` holds `:diagnostics` (`HeexLint.Diagnostic` structs, with
`:suggestions`), `:failures` (templates that could not be parsed),
`:warnings` and `:files`. `HeexLint.Fixer.apply/1` applies the single
suggestions in a list of diagnostics.

## Project API

The information the rules use. Its shapes may change before 1.0:

| Function | Returns |
| --- | --- |
| `HeexLint.Project.load(root, files, settings)` | The project: modules, components, themes. |
| `HeexLint.Project.for_file(project, path)` | The project with the theme of `path`'s app. |
| `HeexLint.Project.resolve(project, module, type, name)` | The component a tag names, or nil. |
| `HeexLint.Project.design_system?(project, component)` | Whether it belongs to the design system. |
| `HeexLint.Project.wrapped(project, component)` | The design-system component a wrapper forwards to. |
| `HeexLint.Project.Component.variants(component)` | Its variant names, or nil. |
| `HeexLint.Project.Component.sizes(component)` | Its size names, or nil. |
| `HeexLint.Theme.load(file)` / `HeexLint.Theme.discover(root)` | A theme, or the stylesheet that imports Tailwind. |
| `HeexLint.Theme.color_tokens(theme)` | The declared color tokens, or nil. |
| `HeexLint.Grammar.Classifier.group_of(class)` | The class group, such as `"bg-color"`. |
| `HeexLint.Grammar.Categories.category_of(group)` | Its category, or nil for layout. |

```elixir
project = HeexLint.Project.load(File.cwd!(), Path.wildcard("lib/**/*.ex"), %{})
button = HeexLint.Project.resolve(project, "MyAppWeb.PageLive", :local_component, "button")
HeexLint.Project.Component.variants(button)
#=> ["primary", "secondary", "danger"]
```

## Custom rules

A module implementing `HeexLint.Rule` (`name/0`, `prepare/2`, `check/3`) can
be listed by name under `rules`. `check/3` receives the file's sites (every
class and style value, resolved to its component) and returns findings with
positions and messages.
