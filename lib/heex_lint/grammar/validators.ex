# Ported from shadcn-ui/cn (packages/cn/src/validators.ts, MIT), itself
# matching tailwind-merge 3.6.0's src/lib/validators.ts (MIT, Dany Castillo),
# through @shadcn/lint's src/grammar/validators.ts.
defmodule HeexLint.Grammar.Validators do
  @moduledoc false

  # cn's config names these predicates in marker form ({"$v": "isNumber"});
  # `check/2` looks them up by that name.

  @names ~w(
    isFraction isNumber isInteger isPercent isTshirtSize isAny isAnyNonArbitrary
    isNamedContainerQuery isArbitrarySize isArbitraryValue isArbitraryLength
    isArbitraryNumber isArbitraryWeight isArbitraryFamilyName isArbitraryPosition
    isArbitraryImage isArbitraryShadow isArbitraryVariable isArbitraryVariableLength
    isArbitraryVariableFamilyName isArbitraryVariablePosition isArbitraryVariableSize
    isArbitraryVariableImage isArbitraryVariableShadow isArbitraryVariableWeight
  )

  @doc "The validator names cn's config may reference."
  def names, do: @names

  @doc "Runs the validator called `name` on `value`."
  @spec check(String.t(), String.t()) :: boolean()
  def check("isFraction", v), do: fraction?(v)
  def check("isNumber", v), do: number?(v)
  def check("isInteger", v), do: integer?(v)
  def check("isPercent", v), do: percent?(v)
  def check("isTshirtSize", v), do: Regex.match?(~r/^(\d+(\.\d+)?)?(xs|sm|md|lg|xl)$/, v)
  def check("isAny", _v), do: true
  def check("isAnyNonArbitrary", v), do: not arbitrary_value?(v) and not arbitrary_variable?(v)
  def check("isNamedContainerQuery", v), do: named_container_query?(v)
  def check("isArbitrarySize", v), do: arbitrary_value(v, &label_size?/1, &never/1)
  def check("isArbitraryValue", v), do: arbitrary_value?(v)
  def check("isArbitraryLength", v), do: arbitrary_value(v, &(&1 == "length"), &length_only?/1)
  def check("isArbitraryNumber", v), do: arbitrary_value(v, &(&1 == "number"), &number?/1)
  def check("isArbitraryWeight", v), do: arbitrary_value(v, &label_weight?/1, &any/1)
  def check("isArbitraryFamilyName", v), do: arbitrary_value(v, &(&1 == "family-name"), &never/1)
  def check("isArbitraryPosition", v), do: arbitrary_value(v, &label_position?/1, &never/1)
  def check("isArbitraryImage", v), do: arbitrary_value(v, &label_image?/1, &image?/1)
  def check("isArbitraryShadow", v), do: arbitrary_value(v, &(&1 == "shadow"), &shadow?/1)
  def check("isArbitraryVariable", v), do: arbitrary_variable?(v)
  def check("isArbitraryVariableLength", v), do: arbitrary_variable(v, &(&1 == "length"), false)

  def check("isArbitraryVariableFamilyName", v),
    do: arbitrary_variable(v, &(&1 == "family-name"), false)

  def check("isArbitraryVariablePosition", v),
    do: arbitrary_variable(v, &label_position?/1, false)

  def check("isArbitraryVariableSize", v), do: arbitrary_variable(v, &label_size?/1, false)
  def check("isArbitraryVariableImage", v), do: arbitrary_variable(v, &label_image?/1, false)
  def check("isArbitraryVariableShadow", v), do: arbitrary_variable(v, &(&1 == "shadow"), true)
  def check("isArbitraryVariableWeight", v), do: arbitrary_variable(v, &label_weight?/1, true)

  def check(name, _v),
    do: raise(ArgumentError, "cn-classifier: unknown validator #{inspect(name)}")

  @doc """
  Whether `value` is a number the way JavaScript's `Number()` reads one.
  """
  @spec number?(String.t()) :: boolean()
  def number?(""), do: false
  def number?(value), do: js_number(value) != :nan

  defp fraction?(v), do: Regex.match?(~r/^\d+(?:\.\d+)?\/\d+(?:\.\d+)?$/, v)

  defp integer?(""), do: false

  defp integer?(v) do
    case js_number(v) do
      :nan -> false
      :infinity -> false
      n -> n == Float.round(n * 1.0)
    end
  end

  defp percent?(v), do: String.ends_with?(v, "%") and number?(String.slice(v, 0..-2//1))

  defp any(_v), do: true
  defp never(_v), do: false

  @doc """
  JavaScript's `Number()`: whitespace-trimmed decimal, exponent, hex, octal,
  binary and Infinity as a float, `:infinity`, or `:nan` for anything else.
  The empty string is `0.0`, as in JavaScript.
  """
  @spec js_number(String.t()) :: float() | :infinity | :nan
  def js_number(value) do
    text = String.trim(value)

    cond do
      text == "" ->
        0.0

      Regex.match?(~r/^[+-]?Infinity$/, text) ->
        :infinity

      Regex.match?(~r/^0[xX][0-9a-fA-F]+$/, text) ->
        text |> String.slice(2..-1//1) |> String.to_integer(16) |> Kernel.*(1.0)

      Regex.match?(~r/^0[oO][0-7]+$/, text) ->
        text |> String.slice(2..-1//1) |> String.to_integer(8) |> Kernel.*(1.0)

      Regex.match?(~r/^0[bB][01]+$/, text) ->
        text |> String.slice(2..-1//1) |> String.to_integer(2) |> Kernel.*(1.0)

      Regex.match?(~r/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/, text) ->
        text |> normalize_decimal() |> Float.parse() |> elem(0)

      true ->
        :nan
    end
  end

  # Float.parse needs digits on both sides of the point.
  defp normalize_decimal(text) do
    text
    |> String.replace(~r/^([+-]?)\./, "\\g{1}0.")
    |> String.replace(~r/\.([eE]|$)/, ".0\\g{1}")
  end

  defp length_only?(v) do
    Regex.match?(
      ~r/\d+(%|px|r?em|[sdl]?v([hwib]|min|max)|pt|pc|in|cm|mm|cap|ch|ex|r?lh|cq(w|h|i|b|min|max))|\b(calc|min|max|clamp)\(.+\)|^0$/,
      v
    ) and not Regex.match?(~r/^(rgba?|hsla?|hwb|(ok)?(lab|lch)|color-mix)\(.+\)$/, v)
  end

  defp shadow?(v),
    do: Regex.match?(~r/^(inset_)?-?((\d+)?\.?(\d+)[a-z]+|0)_-?((\d+)?\.?(\d+)[a-z]+|0)/, v)

  defp image?(v) do
    Regex.match?(
      ~r/^(url|image|image-set|cross-fade|element|(repeating-)?(linear|radial|conic)-gradient)\(.+\)$/,
      v
    )
  end

  defp named_container_query?(v) do
    String.starts_with?(v, "@container") and
      ((String.at(v, 10) == "/" and String.at(v, 11) != nil) or
         (String.at(v, 11) == "s" and String.at(v, 16) != nil and
            String.slice(v, 10, 6) == "-size/") or
         (String.at(v, 11) == "n" and String.at(v, 18) != nil and
            String.slice(v, 10, 8) == "-normal/"))
  end

  defp label_position?(l), do: l in ["position", "percentage"]
  defp label_image?(l), do: l in ["image", "url"]
  defp label_size?(l), do: l in ["length", "size", "bg-size"]
  defp label_weight?(l), do: l in ["number", "weight"]

  @doc false
  def arbitrary_value?(v), do: Regex.match?(~r/^\[(?:(\w[\w-]*):)?(.+)\]$/i, v)

  @doc false
  def arbitrary_variable?(v), do: Regex.match?(~r/^\((?:(\w[\w-]*):)?(.+)\)$/i, v)

  defp arbitrary_value(value, test_label, test_value) do
    case Regex.run(~r/^\[(?:(\w[\w-]*):)?(.+)\]$/i, value) do
      [_, "", inner] -> test_value.(inner)
      [_, label, _inner] -> test_label.(label)
      nil -> false
    end
  end

  defp arbitrary_variable(value, test_label, match_no_label) do
    case Regex.run(~r/^\((?:(\w[\w-]*):)?(.+)\)$/i, value) do
      [_, "", _inner] -> match_no_label
      [_, label, _inner] -> test_label.(label)
      nil -> false
    end
  end
end
