defmodule HeexLint.Value do
  @moduledoc """
  Reads the strings an attribute value can evaluate to.

  A quoted value is one string. A `{...}` value is Elixir code: the strings are
  collected from the positions that end up in the attribute, such as list items,
  `cond && "..."`, `if`/`case`/`cond` branches and `~w(...)`. Conditions are
  skipped, so `if(@size == "sm", do: "p-2")` yields only `"p-2"`.

  Each string is a list of items, so rules can see exactly where interpolation
  touches static text:

    * `{:char, char, {line, column}}`
    * `{:interp, {line, column}}` - a `\#{...}` or `<>` joining runtime values
    * `{:dynamic, {line, column}}` - a runtime value in a value position, such as `@class`
  """

  @type position :: {pos_integer(), pos_integer()}
  @type item :: {:char, String.t(), position()} | {:interp, position()} | {:dynamic, position()}

  @doc """
  Returns the strings `value` can produce, as item lists.

  `indentation` is the indentation stripped from the template, which is added back
  to columns on every line after the first.
  """
  @spec strings(HeexLint.Element.value(), non_neg_integer()) :: [[item()]]
  def strings(nil, _indentation), do: []

  def strings({:string, text, position}, indentation),
    do: [chars(text, position, indentation)]

  def strings({:expr, code, position}, indentation) do
    locate = locator(position, indentation)

    case Code.string_to_quoted(code,
           columns: true,
           token_metadata: true,
           literal_encoder: &encode/2
         ) do
      {:ok, ast} ->
        lines = String.split(code, "\n")
        ast |> values() |> Enum.map(&items(&1, lines, locate, indentation))

      {:error, _} ->
        [[{:dynamic, position}]]
    end
  end

  @doc """
  Splits item lists into whitespace-separated tokens.

  Returns `{:static, text, position}` for plain tokens and
  `{:partial, text, position}` for tokens joined to a runtime value.
  Tokens that are only a runtime value are dropped.
  """
  @spec tokens([[item()]]) :: [{:static | :partial, String.t(), position()}]
  def tokens(strings) do
    Enum.flat_map(strings, fn items ->
      items
      |> Enum.chunk_by(&whitespace?/1)
      |> Enum.reject(&whitespace?(hd(&1)))
      |> Enum.flat_map(&token/1)
    end)
  end

  @doc """
  Returns the static text of an item list, with runtime values removed.
  """
  @spec text([item()]) :: String.t()
  def text(items), do: for({:char, char, _} <- items, into: "", do: char)

  defp token(items) do
    text = Enum.map_join(items, &item_text/1)
    position = item_position(hd(items))

    cond do
      Enum.all?(items, &match?({:char, _, _}, &1)) -> [{:static, text, position}]
      Enum.any?(items, &match?({:char, _, _}, &1)) -> [{:partial, text, position}]
      true -> []
    end
  end

  defp item_text({:char, char, _}), do: char
  defp item_text(_), do: "\#{…}"

  defp item_position({:char, _, position}), do: position
  defp item_position({_, position}), do: position

  defp whitespace?({:char, char, _}), do: String.trim(char) == ""
  defp whitespace?(_), do: false

  # Only strings need metadata; everything else keeps its usual shape.
  defp encode(literal, meta) when is_binary(literal), do: {:ok, {:__block__, meta, [literal]}}
  defp encode(literal, _meta), do: {:ok, literal}

  # Collects the nodes whose value ends up in the attribute.
  defp values({:__block__, _, [literal]} = node) when is_binary(literal), do: [node]
  defp values({:<<>>, _, _} = node), do: [node]
  defp values({:sigil_w, _, _} = node), do: [node]
  defp values(list) when is_list(list), do: Enum.flat_map(list, &values/1)
  defp values({op, _, [_condition, right]}) when op in [:&&, :and], do: values(right)
  defp values({op, _, [left, right]}) when op in [:||, :or], do: values(left) ++ values(right)
  defp values({:<>, _, [left, right]}), do: [{:concat, [left, right]}]

  defp values({op, _, [_condition, branches]}) when op in [:if, :unless] and is_list(branches),
    do: branches |> Keyword.take([:do, :else]) |> Keyword.values() |> Enum.flat_map(&values/1)

  defp values({:case, _, [_subject, [do: clauses]]}), do: clause_values(clauses)
  defp values({:cond, _, [[do: clauses]]}), do: clause_values(clauses)
  defp values({:__block__, _, [_ | _] = exprs}), do: exprs |> List.last() |> values()
  defp values({_, meta, _}) when is_list(meta), do: [{:dynamic, meta}]
  defp values(_literal), do: []

  defp clause_values(clauses) when is_list(clauses),
    do: Enum.flat_map(clauses, fn {:->, _, [_, body]} -> values(body) end)

  defp clause_values(_), do: []

  defp items({:dynamic, meta}, _lines, locate, _indentation), do: [{:dynamic, locate.(meta)}]
  # `"bg-" <> @color` reads as one string whose runtime parts are interpolations.
  defp items({:concat, operands}, lines, locate, indentation) do
    Enum.flat_map(operands, fn operand ->
      case operand do
        {:<>, _, _} -> values(operand)
        {:__block__, _, [literal]} when is_binary(literal) -> [operand]
        {:<<>>, _, _} -> [operand]
        {_, meta, _} -> [{:dynamic, meta}]
        _ -> []
      end
      |> Enum.flat_map(&items(&1, lines, locate, indentation))
      |> Enum.map(fn
        {:dynamic, position} -> {:interp, position}
        item -> item
      end)
    end)
  end

  defp items({:sigil_w, meta, [{:<<>>, _, parts}, _]}, _lines, locate, indentation) do
    {line, column} = locate.(meta)
    # `~w` plus its opening delimiter.
    parts |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> chars({line, column + 3}, indentation)
  end

  defp items({_, meta, parts} = node, lines, locate, indentation) do
    if meta[:delimiter] == "\"" do
      scan(lines, meta[:line], meta[:column] + 1, locate)
    else
      # Heredocs and other delimiters: keep the static text, positioned at the string.
      text = if match?({:__block__, _, _}, node), do: hd(parts), else: static_parts(parts)
      chars(text, locate.(meta), indentation)
    end
  end

  defp static_parts(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join()

  # Walks the source of a double-quoted string from just after its opening quote,
  # so every character keeps its real position.
  defp scan(lines, line, column, locate) do
    lines
    |> Enum.drop(line - 1)
    |> Enum.with_index(line)
    |> Enum.flat_map(fn {text, index} ->
      start = if index == line, do: column, else: 1

      text
      |> String.graphemes()
      |> Enum.with_index(1)
      |> Enum.drop(start - 1)
      |> Enum.map(fn {char, col} -> {char, locate.(line: index, column: col)} end)
      |> Kernel.++([{"\n", locate.(line: index, column: String.length(text) + 1)}])
    end)
    |> scan_string([])
  end

  defp scan_string([], acc), do: Enum.reverse(acc)
  defp scan_string([{"\"", _} | _], acc), do: Enum.reverse(acc)

  defp scan_string([{"\\", _}, {char, position} | rest], acc),
    do: scan_string(rest, [{:char, unescape(char), position} | acc])

  defp scan_string([{"#", position}, {"{", _} | rest], acc),
    do: rest |> skip_interpolation(1) |> scan_string([{:interp, position} | acc])

  defp scan_string([{char, position} | rest], acc),
    do: scan_string(rest, [{:char, char, position} | acc])

  defp skip_interpolation(rest, 0), do: rest
  defp skip_interpolation([], _depth), do: []
  defp skip_interpolation([{"{", _} | rest], depth), do: skip_interpolation(rest, depth + 1)
  defp skip_interpolation([{"}", _} | rest], depth), do: skip_interpolation(rest, depth - 1)
  defp skip_interpolation([_ | rest], depth), do: skip_interpolation(rest, depth)

  defp unescape("n"), do: "\n"
  defp unescape("t"), do: "\t"
  defp unescape(char), do: char

  defp chars(text, {line, column}, indentation) do
    {items, _} =
      text
      |> String.graphemes()
      |> Enum.map_reduce({line, column}, fn
        "\n", {l, c} -> {{:char, "\n", {l, c}}, {l + 1, indentation + 1}}
        char, {l, c} -> {{:char, char, {l, c}}, {l, c + 1}}
      end)

    items
  end

  # Maps positions inside the expression's code to positions in the file.
  defp locator({base_line, base_column}, indentation) do
    fn meta ->
      line = meta[:line] || 1
      column = meta[:column] || 1

      if line == 1,
        do: {base_line, base_column + column - 1},
        else: {base_line + line - 1, column + indentation}
    end
  end
end
