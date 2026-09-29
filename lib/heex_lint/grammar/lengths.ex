defmodule HeexLint.Grammar.Lengths do
  @moduledoc """
  A CSS length in pixels, with enough `calc()` to read the scales a theme
  declares. Anything else (percentages, `clamp()`, unknown units) is `nil`.
  Ported from @shadcn/lint's `src/grammar/lengths.ts` (MIT).
  """

  @rem 16

  @doc """
  The pixel value of `value`, or `nil`.

      iex> HeexLint.Grammar.Lengths.px("0.75rem")
      12.0
      iex> HeexLint.Grammar.Lengths.px("calc(var(--x) - 2px)")
      nil
      iex> HeexLint.Grammar.Lengths.px("calc(0.5rem + 2px)")
      10.0
  """
  @spec px(String.t()) :: float() | nil
  def px(value) do
    with tokens when is_list(tokens) and tokens != [] <- tokenize(String.trim(value), []),
         {result, []} <- sum(tokens) do
      case result do
        {:px, px} -> px * 1.0
        {:n, n} when n == 0 -> 0.0
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Formats pixels the way messages show them.

      iex> HeexLint.Grammar.Lengths.format_px(13.0)
      "13px"
      iex> HeexLint.Grammar.Lengths.format_px(13.333333)
      "13.33px"
  """
  @spec format_px(number()) :: String.t()
  def format_px(px) do
    rounded = Float.round(px * 1.0, 2)

    text =
      if rounded == trunc(rounded),
        do: Integer.to_string(trunc(rounded)),
        else: Float.to_string(rounded)

    text <> "px"
  end

  @token ~r/\A\s*(?:(calc\(|\()|(\))|([+\-*\/])|(\d*\.?\d+(?:e[+-]?\d+)?)(px|rem|em|%)?)/i

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(input, acc) do
    case Regex.run(@token, input, return: :index) do
      [{0, 0} | _] ->
        if String.trim(input) == "", do: Enum.reverse(acc), else: nil

      [{0, length} | groups] ->
        rest = binary_part(input, length, byte_size(input) - length)

        case token(input, groups) do
          :error -> nil
          token -> tokenize(rest, [token | acc])
        end

      nil ->
        if String.trim(input) == "", do: Enum.reverse(acc), else: nil
    end
  end

  defp token(input, groups) do
    [open, close, op, number, unit] =
      groups
      |> Enum.concat(List.duplicate({-1, 0}, 5))
      |> Enum.take(5)
      |> Enum.map(fn
        {-1, _} -> nil
        {start, len} -> binary_part(input, start, len)
      end)

    cond do
      open not in [nil, ""] -> :open
      close not in [nil, ""] -> :close
      op not in [nil, ""] -> {:op, op}
      true -> number_token(number, String.downcase(unit || ""))
    end
  end

  defp number_token(number, unit) do
    value = parse_float(number)

    case unit do
      "%" -> :error
      "px" -> {:num, {:px, value}}
      unit when unit in ["rem", "em"] -> {:num, {:px, value * @rem}}
      _ -> {:num, {:n, value}}
    end
  end

  defp parse_float(text) do
    text
    |> String.replace(~r/^\./, "0.")
    |> String.replace(~r/\.(e|E|$)/, ".0\\1")
    |> Float.parse()
    |> elem(0)
  end

  defp sum(tokens) do
    with {left, rest} <- product(tokens), do: sum_rest(left, rest)
  end

  defp sum_rest(nil, rest), do: {nil, rest}

  defp sum_rest(left, [{:op, op} | rest]) when op in ["+", "-"] do
    case product(rest) do
      {nil, rest} -> {nil, rest}
      {right, rest} -> sum_rest(add(left, right, if(op == "+", do: 1, else: -1)), rest)
    end
  end

  defp sum_rest(left, rest), do: {left, rest}

  defp product(tokens) do
    with {left, rest} <- factor(tokens), do: product_rest(left, rest)
  end

  defp product_rest(nil, rest), do: {nil, rest}

  defp product_rest(left, [{:op, op} | rest]) when op in ["*", "/"] do
    case factor(rest) do
      {nil, rest} ->
        {nil, rest}

      {right, rest} ->
        product_rest(if(op == "*", do: multiply(left, right), else: divide(left, right)), rest)
    end
  end

  defp product_rest(left, rest), do: {left, rest}

  defp factor([{:num, value} | rest]), do: {value, rest}

  defp factor([{:op, "-"} | rest]) do
    case factor(rest) do
      {{:px, px}, rest} -> {{:px, -px}, rest}
      {{:n, n}, rest} -> {{:n, -n}, rest}
      other -> other
    end
  end

  defp factor([{:op, "+"} | rest]), do: factor(rest)

  defp factor([:open | rest]) do
    case sum(rest) do
      {inner, [:close | rest]} -> {inner, rest}
      {_inner, rest} -> {nil, rest}
    end
  end

  defp factor([_ | rest]), do: {nil, rest}
  defp factor([]), do: {nil, []}

  defp add({:px, a}, {:px, b}, sign), do: {:px, a + sign * b}
  defp add({:n, a}, {:n, b}, sign), do: {:n, a + sign * b}
  defp add({:n, a}, {:px, b}, sign) when a == 0, do: {:px, sign * b}
  defp add({:px, _} = a, {:n, b}, _sign) when b == 0, do: a
  defp add(_, _, _), do: nil

  defp multiply({:n, a}, {:n, b}), do: {:n, a * b}
  defp multiply({:px, a}, {:n, b}), do: {:px, a * b}
  defp multiply({:n, a}, {:px, b}), do: {:px, a * b}
  defp multiply(_, _), do: nil

  defp divide(_a, {:n, b}) when b == 0, do: nil
  defp divide({:px, a}, {:n, b}), do: {:px, a / b}
  defp divide({:n, a}, {:n, b}), do: {:n, a / b}
  defp divide(_, _), do: nil
end
