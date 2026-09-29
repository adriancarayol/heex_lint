defmodule HeexLint.Fixer do
  @moduledoc """
  Applies suggestions to files. A suggestion rewrites one class inside a
  literal's own source text, never re-serializing it. Only exact
  suggestions apply: rewrites that generate the same CSS, such as an exact
  scale step or the variable shorthand. A nearest color or a spelling
  correction is a choice, left to the reader.
  """

  alias HeexLint.Diagnostic
  alias HeexLint.Grammar.Classes

  @doc "Whether `diagnostic` has exactly one suggestion, and it is exact."
  @spec fixable?(Diagnostic.t()) :: boolean()
  def fixable?(%Diagnostic{suggestions: [%{fix: %{}, exact: true}]}), do: true
  def fixable?(_), do: false

  @doc """
  Applies every exact suggestion in `diagnostics` and returns how many were
  applied. Several fixes in one literal compose, so one run converges.
  """
  @spec apply([Diagnostic.t()]) :: non_neg_integer()
  def apply(diagnostics) do
    diagnostics
    |> Enum.filter(&fixable?/1)
    |> Enum.map(fn %Diagnostic{suggestions: [%{fix: fix}]} -> fix end)
    |> Enum.uniq_by(&{&1.file, &1.from, &1.token})
    |> Enum.group_by(& &1.file)
    |> Enum.map(fn {file, fixes} -> apply_file(file, fixes) end)
    |> Enum.sum()
  end

  defp apply_file(file, fixes) do
    contents = File.read!(file)
    lines = String.split(contents, "\n")

    # One edit per literal, from the end of the file backwards, so earlier
    # offsets stay valid.
    {contents, applied} =
      fixes
      |> Enum.group_by(&{&1.from, &1.old})
      |> Enum.sort_by(fn {{from, _old}, _} -> from end, :desc)
      |> Enum.reduce({contents, 0}, fn {{from, old}, literal_fixes}, {contents, applied} ->
        offset = offset(lines, from)
        size = byte_size(old)

        new =
          Enum.reduce(literal_fixes, old, fn fix, text ->
            Classes.replace_class(text, fix.token, fix.replacement)
          end)

        if offset + size <= byte_size(contents) and binary_part(contents, offset, size) == old do
          rest = binary_part(contents, offset + size, byte_size(contents) - offset - size)
          {binary_part(contents, 0, offset) <> new <> rest, applied + length(literal_fixes)}
        else
          {contents, applied}
        end
      end)

    if applied > 0, do: File.write!(file, contents)
    applied
  end

  # The byte offset of a 1-based line and character column.
  defp offset(lines, {line, column}) do
    before = lines |> Enum.take(line - 1) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
    current = Enum.at(lines, line - 1, "")
    before + byte_size(String.slice(current, 0, column - 1))
  end
end
