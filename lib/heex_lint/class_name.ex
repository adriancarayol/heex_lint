defmodule HeexLint.ClassName do
  @moduledoc """
  Splits a Tailwind class into its variants and utility.

      iex> HeexLint.ClassName.parse("md:hover:!-mt-4")
      %HeexLint.ClassName{
        raw: "md:hover:!-mt-4",
        variants: ["md", "hover"],
        utility: "mt-4",
        important: true,
        negative: true
      }
  """

  defstruct [:raw, :utility, variants: [], important: false, negative: false]

  @type t :: %__MODULE__{
          raw: String.t(),
          utility: String.t(),
          variants: [String.t()],
          important: boolean(),
          negative: boolean()
        }

  @spec parse(String.t()) :: t()
  def parse(raw) do
    {base, variants} = raw |> split_variants() |> List.pop_at(-1)
    {base, important} = important(base)
    {utility, negative} = negative(base)

    %__MODULE__{
      raw: raw,
      utility: utility,
      variants: variants,
      important: important,
      negative: negative
    }
  end

  @doc """
  Returns the class with its utility replaced, keeping variants and modifiers.
  """
  @spec with_utility(t(), String.t()) :: String.t()
  def with_utility(%__MODULE__{} = class, utility) do
    utility = if class.negative, do: "-" <> utility, else: utility
    utility = if class.important, do: utility <> "!", else: utility
    Enum.join(class.variants ++ [utility], ":")
  end

  # Split on `:` outside of `[...]` and `(...)`, so `[&:hover]:p-2` and
  # `bg-[url(a:b)]` stay intact.
  defp split_variants(raw) do
    {parts, current, _depth} =
      raw
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ":", {parts, current, 0} ->
          {[current | parts], "", 0}

        char, {parts, current, depth} when char in ["[", "("] ->
          {parts, current <> char, depth + 1}

        char, {parts, current, depth} when char in ["]", ")"] ->
          {parts, current <> char, max(depth - 1, 0)}

        char, {parts, current, depth} ->
          {parts, current <> char, depth}
      end)

    Enum.reverse([current | parts])
  end

  defp important("!" <> rest), do: {rest, true}

  defp important(base) do
    if String.ends_with?(base, "!"),
      do: {String.trim_trailing(base, "!"), true},
      else: {base, false}
  end

  defp negative("-" <> rest), do: {rest, true}
  defp negative(base), do: {base, false}
end
