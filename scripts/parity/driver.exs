# Lints the cases with HeexLint and prints them the way driver.ts does.
# Run from the repository root: MIX_ENV=test mix run scripts/parity/driver.exs

here = Path.expand(".", __DIR__)
dir = Path.join(System.tmp_dir!(), "heex_lint_parity_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)

cases = here |> Path.join("cases.txt") |> File.read!() |> String.split("\n", trim: true)

{lines, where} =
  cases
  |> Enum.with_index()
  |> Enum.reduce({[], %{}}, fn {token, i}, {lines, where} ->
    Enum.reduce(["div", "Button", "CardTitle"], {lines, where}, fn kind, {lines, where} ->
      line =
        case kind do
          "div" -> ~s(<div class="#{token}" />)
          "Button" -> ~s(<.button class="#{token}">x</.button>)
          "CardTitle" -> ~s(<.card_title class="#{token}">x</.card_title>)
        end

      {lines ++ [line], Map.put(where, length(lines), {i, kind})}
    end)
  end)

files = %{"lib/app_web/live/page_live.ex" => HeexLint.TestProject.live(Enum.join(lines, "\n"))}

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
           message: %{spacing: "S {{className}} {{sizes|nosize}} {{around}}"},
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

diagnostics = HeexLint.TestProject.lint(dir, files, rules: rules)

# The template starts on line 6 of the generated module.
out =
  diagnostics
  |> Enum.filter(&String.ends_with?(&1.file, "page_live.ex"))
  |> Enum.map(fn d ->
    {i, kind} = Map.get(where, d.line - 6, {"?", "?"})

    message =
      d.message
      |> String.replace("<.button>", "<Button>")
      |> String.replace("<.card_title>", "<CardTitle>")
      |> String.replace(".card_title", "CardTitle")
      |> String.replace(".button", "Button")
      |> String.replace("lib/app_web/components/core_components.ex", "FILE")
      |> String.replace("assets/css/app.css", "THEME")

    "#{i}\t#{kind}\t#{d.rule}\t#{message}"
  end)
  |> Enum.sort()

File.write!(Path.join(here, "ours_out.tsv"), Enum.join(out, "\n") <> "\n")
IO.puts("#{length(out)} findings")
File.rm_rf!(dir)
