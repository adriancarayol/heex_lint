# Lints style_cases.txt with HeexLint and prints it the way style_driver.ts does.
# Run from the repository root: MIX_ENV=test mix run scripts/parity/style_driver.exs

here = Path.expand(".", __DIR__)
dir = Path.join(System.tmp_dir!(), "heex_lint_parity_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)

lines =
  (System.get_env("CASES") || Path.join(here, "style_cases.txt"))
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&String.starts_with?(&1, "#"))

out =
  Enum.flat_map(lines, fn line ->
    [name, _js_names, _js, names, declared, body, template] = String.split(line, "\t")

    options =
      case names do
        "-" -> []
        "" -> [allow_dynamic_identifiers: []]
        names -> [allow_dynamic_identifiers: String.split(names, ",")]
      end

    module = """
    defmodule AppWeb.Page do
      use AppWeb, :html

      #{declared}
      def page(assigns) do
        #{body}
        ~H\"\"\"
        #{template}
        \"\"\"
      end
    end
    """

    dir
    |> HeexLint.TestProject.lint(%{"lib/app_web/page.ex" => module},
      rules: [no_inline_styles: {:error, options}]
    )
    |> Enum.map(&"#{name}\tno_inline_styles\t#{&1.message}")
    |> Enum.uniq()
  end)

File.write!(Path.join(here, "ours_out.tsv"), Enum.map_join(out, &(&1 <> "\n")))
IO.puts("#{length(out)} findings")
File.rm_rf!(dir)
