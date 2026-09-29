defmodule HeexLint.Suppressions do
  @moduledoc """
  Inline exceptions, documented next to the code:

      <%!-- heex-lint-disable-next-line no_raw_colors -- Partner brand color, approved by design. --%>
      <span class="bg-amber-400">Sponsor</span>

      # heex-lint-disable-next-line no_arbitrary_values -- the grid is data-driven
      class = "grid-cols-[repeat(auto-fill,minmax(12rem,1fr))]"

  Directives:

    * `heex-lint-disable-next-line [rules]` - the next line
    * `heex-lint-disable-line [rules]` - its own line
    * `heex-lint-disable-file [rules]` - the whole file

  Rules are separated by commas or spaces; none means every rule. Text
  after ` -- ` is the reason. `grep -rn "heex-lint-disable"` finds them all.
  """

  @directive ~r/heex-lint-disable(-next-line|-line|-file)?(?:\s+([^\n]*?))?(?:\s+--\s.*?)?\s*(?:--%>|%>|-->|\*\/)?\s*$/

  @doc """
  Removes the diagnostics a directive in `source` disables.
  """
  @spec apply([HeexLint.Diagnostic.t()], HeexLint.Project.Source.t()) :: [HeexLint.Diagnostic.t()]
  def apply(diagnostics, source) do
    directives = directives(source)

    if directives == [] do
      diagnostics
    else
      Enum.reject(diagnostics, fn diagnostic ->
        Enum.any?(directives, fn {scope, line, rules} ->
          covers?(scope, line, diagnostic.line) and
            (rules == [] or Atom.to_string(diagnostic.rule) in rules)
        end)
      end)
    end
  end

  defp covers?(:file, _line, _target), do: true
  defp covers?(:line, line, target), do: line == target
  defp covers?(:next_line, line, target), do: line + 1 == target

  defp directives(source) do
    source.lines
    |> Tuple.to_list()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      if String.contains?(text, "heex-lint-disable") do
        case Regex.run(@directive, text) do
          nil -> []
          [_ | groups] -> [directive(groups, line)]
        end
      else
        []
      end
    end)
  end

  defp directive(groups, line) do
    [kind | rest] = groups ++ [nil]

    scope =
      case kind do
        "-next-line" -> :next_line
        "-line" -> :line
        _ -> :file
      end

    rules =
      rest
      |> List.first()
      |> Kernel.||("")
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.map(&String.replace_prefix(&1, "heex_lint/", ""))

    {scope, line, rules}
  end
end
