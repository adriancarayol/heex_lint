defmodule HeexLint.Code do
  @moduledoc false

  # Helpers for reading Elixir source: parsing with positions and reading
  # the shapes the linter cares about.

  @doc """
  Parses `source` with line and column metadata. String literals keep
  their metadata through `{:__block__, meta, [string]}`.
  """
  def parse(source, opts \\ []) do
    Code.string_to_quoted(
      source,
      [
        columns: true,
        token_metadata: true,
        literal_encoder: &encode/2,
        emit_warnings: false
      ] ++ opts
    )
  end

  defp encode(literal, meta) when is_binary(literal), do: {:ok, {:__block__, meta, [literal]}}
  defp encode(literal, _meta), do: {:ok, literal}

  @doc "The module name an alias node spells, such as `\"MyApp.Web\"`."
  def alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  def alias_name(atom) when is_atom(atom) and atom not in [nil, true, false] do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name
      _ -> nil
    end
  end

  def alias_name(_), do: nil

  @doc "The string a literal node holds, or nil."
  def string({:__block__, _, [text]}) when is_binary(text), do: text
  def string(text) when is_binary(text), do: text
  def string(_), do: nil

  @doc "The atom or string a literal node names, as a string."
  def name(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  def name(other), do: string(other)

  @doc """
  The strings a `values:` option lists: `~w(a b)`, `["a", "b"]` or `[:a, :b]`.
  """
  def string_list({:sigil_w, _, [{:<<>>, _, parts}, _]}) do
    parts |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> String.split(~r/\s+/, trim: true)
  end

  def string_list(list) when is_list(list) do
    names = Enum.map(list, &name/1)
    if Enum.all?(names, &is_binary/1), do: names
  end

  def string_list(_), do: nil

  @doc "The body statements of a `do` block."
  def statements({:__block__, _, statements}), do: statements
  def statements(nil), do: []
  def statements(statement), do: [statement]

  @doc "The keyword options of a call's last argument, when it is a keyword list."
  def keyword(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)), do: list, else: []
  end

  def keyword(_), do: []
end
