# Lints the cases with HeexLint and prints them the way driver.ts does.
# Run from the repository root: MIX_ENV=test mix run scripts/parity/driver.exs
#
# CONFIG picks the rule options, THEME the CSS file used as the project's
# theme (HeexLint.TestProject's if unset), CASES the class list (cases.txt
# if unset).

here = Path.expand(".", __DIR__)
dir = Path.join(System.tmp_dir!(), "heex_lint_parity_#{System.unique_integer([:positive])}")
# The number repeats between runs, and a run that crashed leaves its directory.
File.rm_rf!(dir)
File.mkdir_p!(dir)

cases =
  (System.get_env("CASES") || Path.join(here, "cases.txt"))
  |> File.read!()
  |> String.split("\n", trim: true)

theme =
  case System.get_env("THEME") do
    nil -> HeexLint.TestProject.theme()
    path -> File.read!(path)
  end

kinds = [
  {"div", ~s(<div class="$" />)},
  {"Button", ~s(<.button class="$">x</.button>)},
  {"CardTitle", ~s(<.card_title class="$">x</.card_title>)},
  {"Panel", ~s(<AppWeb.Panels.panel class="$" />)},
  {"PanelTitle", ~s(<AppWeb.Panels.panel title_class="$" />)},
  {"PanelFooter", ~s(<AppWeb.Panels.panel footer_class="$" />)},
  {"PassedPanel", ~s(<AppWeb.Panels.passed_panel class="$" />)},
  {"PassedTitle", ~s(<AppWeb.Panels.passed_panel title_class="$" />)},
  {"PassedOther", ~s(<AppWeb.Panels.passed_panel other_class="$" />)}
]

{lines, where} =
  cases
  |> Enum.reduce({[], %{}}, fn token, {lines, where} ->
    Enum.reduce(kinds, {lines, where}, fn {kind, tag}, {lines, where} ->
      {[String.replace(tag, "$", token) | lines], Map.put(where, map_size(where), {token, kind})}
    end)
  end)

# Wrappers with more than one class prop: each goes where the wrapper hands it.
panels = """
defmodule AppWeb.Panels do
  use AppWeb, :html

  attr :class, :any, default: nil
  attr :title_class, :any, default: nil
  attr :footer_class, :any, default: nil
  slot :inner_block

  def panel(assigns) do
    ~H\"\"\"
    <.card class={@class}>
      <.card_title class={@title_class}>{render_slot(@inner_block)}</.card_title>
      <div class={@footer_class} />
    </.card>
    \"\"\"
  end

  attr :rest, :global

  def passed_panel(assigns) do
    ~H\"\"\"
    <.panel {@rest} />
    \"\"\"
  end
end
"""

files = %{
  "assets/css/app.css" => theme,
  "lib/app_web/panels.ex" => panels,
  "lib/app_web/live/page_live.ex" =>
    HeexLint.TestProject.live(lines |> Enum.reverse() |> Enum.join("\n"))
}

# The same Tailwind the React fixture resolves, so both linters can ask it.
File.ln_s!(Path.join(here, "node_modules"), Path.join(dir, "node_modules"))

rules =
  case System.get_env("CONFIG") do
    "3" ->
      [no_unknown_classes: :error, no_raw_colors: :error]

    "2" ->
      [
        no_restyle:
          {:error,
           allow: ["layout"],
           deny: ["w-*"],
           message: %{spacing: "S {{className}} {{sizes|nosize}} {{around}} P[{{prop}}]"},
           contracts: [
             [
               pattern: "^card_title$",
               allow: ["layout", "typography"],
               deny: ["font-*"],
               message: %{color: "C {{className}} on {{component}}: {{variants|none}} {{entries}}"}
             ]
           ]},
        no_raw_colors:
          {:error,
           allow: ["*-amber-*", "*-lime-*"],
           deny: ["bg-amber-500"],
           message: "RC {{className}} [{{suggestions|-}}] ({{tokens}}) {{file}}",
           contracts: [[pattern: "^button$", allow: ["*-red-*"]]]},
        no_arbitrary_values:
          {:error,
           allow: ["layout", "p-[13px]", "rounded"],
           message: "AV {{className}} [{{suggestions|none}}] <{{replacement}}>"}
      ]

    _ ->
      [
        no_restyle: {:error, allow: ["layout"]},
        no_raw_colors: :error,
        no_arbitrary_values: {:error, allow: ["layout"]}
      ]
  end

diagnostics =
  HeexLint.TestProject.lint(dir, files,
    rules: rules,
    settings: [theme_imports: ["^parity-installed-kit/theme", "^parity-installed-bare/"]]
  )

# The template starts on line 6 of the generated module.
out =
  diagnostics
  |> Enum.filter(&String.ends_with?(&1.file, "page_live.ex"))
  |> Enum.map(fn d ->
    {token, kind} = Map.get(where, d.line - 6, {"?", "?"})

    message =
      d.message
      |> String.replace("<.button>", "<Button>")
      |> String.replace("<.card_title>", "<CardTitle>")
      |> String.replace(".card_title", "CardTitle")
      |> String.replace(".passed_panel", "PassedPanel")
      |> String.replace(".panel", "Panel")
      |> String.replace(".card", "Card")
      |> String.replace(".button", "Button")
      |> String.replace("title_class", "titleClassName")
      |> String.replace("footer_class", "footerClassName")
      |> String.replace("other_class", "otherClassName")
      |> String.replace("forwards class to", "forwards className to")
      |> String.replace("P[class]", "P[className]")
      |> String.replace("lib/app_web/components/core_components.ex", "FILE")
      |> String.replace("assets/css/app.css", "THEME")

    "#{token}\t#{kind}\t#{d.rule}\t#{message}"
  end)
  |> Enum.sort()

File.write!(Path.join(here, "ours_out.tsv"), Enum.map_join(out, &(&1 <> "\n")))
IO.puts("#{length(out)} findings")
File.rm_rf!(dir)
