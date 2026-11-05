defmodule HeexLint.Grammar.Classes do
  @moduledoc """
  Reading a single Tailwind class: its variants, base, markers and shape.
  Ported from @shadcn/lint's `src/grammar/classes.ts` (MIT).
  """

  @palette ~w(
    slate gray zinc neutral stone mauve olive mist taupe red orange amber yellow lime
    green emerald teal cyan sky blue indigo violet purple fuchsia pink rose
  )

  # The utilities that take a color. Longest alternatives first, so
  # text-shadow-primary is a text-shadow color, not text "shadow-primary".
  @color_prefix "^(?:text-shadow|inset-shadow|inset-ring|drop-shadow|scrollbar-(?:thumb|track)|ring-offset|border(?:-[trblxyse]|-[bi][se])?|divide(?:-[xy])?|mask-(?:linear|radial|conic|[trblxy])-(?:from|to)|bg|text|ring|outline|fill|stroke|from|via|to|accent|caret|decoration|placeholder|shadow)-"

  # A bracket or paren holds no other: each match attempt then stops at the next
  # one, so /[/[/[ is not searched once per slash.
  @opacity_modifier "\\/(?:[\\w.%]+|\\[[^\\[\\]]*\\]|\\([^()]*\\))$"

  # Read below through sigil_r, as the literals they are, so that each is compiled with
  # this module. Compiled on each call, these took a third of the time on a class.
  @palette_class "#{@color_prefix}(?:#{Enum.join(@palette, "|")})-\\d{2,3}(?:#{@opacity_modifier})?$"

  # What `\s` reads in a class string.
  @whitespace [" ", "\t", "\n", "\v", "\f", "\r"]

  # Marker classes style nothing and have no group; they count as layout.
  @markers MapSet.new(~w(group peer dark light))

  @doc "The palette color names, such as `zinc`."
  def palette_names, do: @palette

  @doc "A regex matching the color utility prefix of a class base, such as `bg-`."
  def color_prefix, do: sigil_r(<<unquote(@color_prefix)>>, [])

  @doc "A regex matching an opacity modifier at the end of a class base, such as `/50`."
  def opacity_modifier, do: sigil_r(<<unquote(@opacity_modifier)>>, [])

  @doc """
  Splits a class into its variants and base. Brackets and parentheses keep
  their inner colons, so `[&:hover]:p-2` and `font-(family-name:--x)` stay whole.

      iex> HeexLint.Grammar.Classes.split_variants("md:hover:bg-red-500")
      {["md", "hover"], "bg-red-500"}
  """
  @spec split_variants(String.t()) :: {[String.t()], String.t()}
  def split_variants(token) do
    if String.contains?(token, ":") do
      {segments, current, _, _} =
        token
        |> String.graphemes()
        |> Enum.reduce({[], "", 0, 0}, fn char, {segments, current, brackets, parens} ->
          {brackets, parens} =
            case char do
              "[" -> {brackets + 1, parens}
              "]" -> {brackets - 1, parens}
              "(" when brackets == 0 -> {brackets, parens + 1}
              ")" when brackets == 0 -> {brackets, parens - 1}
              _ -> {brackets, parens}
            end

          if char == ":" and brackets == 0 and parens == 0,
            do: {[current | segments], "", brackets, parens},
            else: {segments, current <> char, brackets, parens}
        end)

      {Enum.reverse(segments), current}
    else
      {[], token}
    end
  end

  @doc "Splits a class string on whitespace."
  @spec split_classes(String.t()) :: [String.t()]
  def split_classes(value), do: String.split(value, ~r/\s+/, trim: true)

  @doc """
  The base class that contracts and classification match against: no
  variants, important markers or negative prefix.

      iex> HeexLint.Grammar.Classes.normalize("md:!-mt-4")
      "mt-4"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(token) do
    {_, base} = split_variants(token)

    base
    |> String.replace(~r/^!/, "")
    |> String.replace(~r/!$/, "")
    |> String.replace(~r/^-/, "")
  end

  @doc "Whether `token` is a marker class such as `group`, `peer/name` or `dark`."
  @spec marker?(String.t()) :: boolean()
  def marker?(token) do
    token |> normalize() |> String.split("/") |> hd() |> then(&MapSet.member?(@markers, &1))
  end

  @doc """
  Whether `token` has an arbitrary value (`mt-[13px]`, `bg-[#333]`) or is an
  arbitrary property (`[color:red]`). The shorthand `bg-(--x)` is not: it
  names a CSS variable.
  """
  @spec arbitrary_value?(String.t()) :: boolean()
  def arbitrary_value?(token) do
    if String.contains?(token, "[") do
      {_, base} = split_variants(token)
      arbitrary_utility?(base) or arbitrary_property?(base)
    else
      false
    end
  end

  # Searched for rather than matched, so a token of a thousand unclosed brackets
  # costs one pass, not one per bracket. When no `]` follows the first `-[`, none
  # follows a later one.
  defp arbitrary_utility?(base) do
    case index_from(base, "-[", 0) do
      nil -> false
      open -> index_from(base, "]", open + 2) != nil
    end
  end

  # `[property:value]`: no other `]`, and a colon with something on each side.
  defp arbitrary_property?(base) do
    size = byte_size(base)

    size > 2 and :binary.first(base) == ?[ and :binary.last(base) == ?] and
      index_from(binary_part(base, 0, size - 1), "]", 0) == nil and
      index_from(binary_part(base, 0, size - 2), ":", 2) != nil
  end

  @doc false
  # JavaScript's `indexOf`: where `pattern` first starts at or after `from`, or nil.
  @spec index_from(String.t(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def index_from(text, _pattern, from) when from >= byte_size(text), do: nil

  def index_from(text, pattern, from) do
    case :binary.match(text, pattern, scope: {from, byte_size(text) - from}) do
      {at, _length} -> at
      :nomatch -> nil
    end
  end

  @doc """
  Whether `token` uses the raw Tailwind palette, such as `hover:bg-zinc-100/50`.
  """
  @spec palette_class?(String.t()) :: boolean()
  def palette_class?(token) do
    Regex.match?(palette_regex(), normalize(token))
  end

  defp palette_regex, do: sigil_r(<<unquote(@palette_class)>>, [])

  @doc """
  `token` with its base replaced by `base`, keeping variants and the
  important and negative markers.

      iex> HeexLint.Grammar.Classes.with_base("hover:!bg-zinc-100", "bg-muted")
      "hover:!bg-muted"
  """
  @spec with_base(String.t(), String.t()) :: String.t()
  def with_base(token, base) do
    {variants, original} = split_variants(token)
    leading = if String.starts_with?(original, "!"), do: "!", else: ""
    trailing = if leading == "" and String.ends_with?(original, "!"), do: "!", else: ""
    stripped = original |> String.replace(~r/^!/, "") |> String.replace(~r/!$/, "")
    negative = if String.starts_with?(stripped, "-"), do: "-", else: ""
    prefix = if variants == [], do: "", else: Enum.join(variants, ":") <> ":"
    "#{prefix}#{leading}#{negative}#{base}#{trailing}"
  end

  @doc """
  Replaces the first whole occurrence of `token` in the class string `value`.
  Read as plain text, since a token past about 32 KB is too long to be a regex.

      iex> HeexLint.Grammar.Classes.replace_class("x-p-1 p-1 p-1x", "p-1", "2xl:p-2")
      "x-p-1 2xl:p-2 p-1x"
  """
  @spec replace_class(String.t(), String.t(), String.t()) :: String.t()
  def replace_class(value, "", _replacement), do: value

  def replace_class(value, token, replacement) do
    case whole_occurrence(value, token, 0) do
      nil ->
        value

      at ->
        after_token = at + byte_size(token)

        binary_part(value, 0, at) <>
          replacement <> binary_part(value, after_token, byte_size(value) - after_token)
    end
  end

  defp whole_occurrence(value, token, from) do
    with at when at != nil <- index_from(value, token, from) do
      if class_edge?(value, at - 1) and class_edge?(value, at + byte_size(token)) do
        at
      else
        # Nothing later in this word starts a whole one.
        case :binary.match(value, @whitespace, scope: {at, byte_size(value) - at}) do
          {space, 1} -> whole_occurrence(value, token, space + 1)
          :nomatch -> nil
        end
      end
    end
  end

  defp class_edge?(value, at) when at < 0 or at >= byte_size(value), do: true
  defp class_edge?(value, at), do: <<:binary.at(value, at)>> in @whitespace
end
