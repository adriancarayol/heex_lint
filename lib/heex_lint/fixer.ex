defmodule HeexLint.Fixer do
  @moduledoc """
  Applies suggestions to files. A suggestion rewrites one class inside a
  literal's own source text, never re-serializing it; a diagnostic with
  more than one suggestion is a choice, so only single suggestions apply.
  """

  alias HeexLint.Diagnostic

  @doc "Whether `diagnostic` has exactly one applicable suggestion."
  @spec fixable?(Diagnostic.t()) :: boolean()
  def fixable?(%Diagnostic{suggestions: [%{fix: %{}}]}), do: true
  def fixable?(_), do: false

  @doc """
  Applies every single suggestion in `diagnostics`, one per literal, and
  returns how many were applied.
  """
  @spec apply([Diagnostic.t()]) :: non_neg_integer()
  def apply(diagnostics) do
    diagnostics
    |> Enum.filter(&fixable?/1)
    |> Enum.map(fn %Diagnostic{suggestions: [%{fix: fix}]} -> fix end)
    |> Enum.uniq_by(&{&1.file, &1.from})
    |> Enum.group_by(& &1.file)
    |> Enum.map(fn {file, fixes} -> apply_file(file, fixes) end)
    |> Enum.sum()
  end

  defp apply_file(file, fixes) do
    contents = File.read!(file)
    lines = String.split(contents, "\n")

    # From the end of the file backwards, so earlier offsets stay valid.
    {contents, applied} =
      fixes
      |> Enum.sort_by(& &1.from, :desc)
      |> Enum.reduce({contents, 0}, fn fix, {contents, applied} ->
        offset = offset(lines, fix.from)
        size = byte_size(fix.old)

        if offset + size <= byte_size(contents) and binary_part(contents, offset, size) == fix.old do
          {binary_part(contents, 0, offset) <>
             fix.new <> binary_part(contents, offset + size, byte_size(contents) - offset - size),
           applied + 1}
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
