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

  @opacity_modifier "\\/(?:[\\w.%]+|\\[[^\\]]*\\]|\\([^)]*\\))$"

  # Marker classes style nothing and have no group; they count as layout.
  @markers MapSet.new(~w(group peer dark light))

  @doc "The palette color names, such as `zinc`."
  def palette_names, do: @palette

  @doc "A regex matching the color utility prefix of a class base, such as `bg-`."
  def color_prefix, do: Regex.compile!(@color_prefix)

  @doc "A regex matching an opacity modifier at the end of a class base, such as `/50`."
  def opacity_modifier, do: Regex.compile!(@opacity_modifier)

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
      Regex.match?(~r/-\[[^\]]*\]/, base) or Regex.match?(~r/^\[[^\]]+:[^\]]+\]$/, base)
    else
      false
    end
  end

  @doc """
  Whether `token` uses the raw Tailwind palette, such as `hover:bg-zinc-100/50`.
  """
  @spec palette_class?(String.t()) :: boolean()
  def palette_class?(token) do
    Regex.match?(palette_regex(), normalize(token))
  end

  defp palette_regex do
    Regex.compile!(
      "#{@color_prefix}(?:#{Enum.join(@palette, "|")})-\\d{2,3}(?:#{@opacity_modifier})?$"
    )
  end

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
  """
  @spec replace_class(String.t(), String.t(), String.t()) :: String.t()
  def replace_class(value, token, replacement) do
    pattern = Regex.compile!("(^|\\s)" <> Regex.escape(token) <> "(?=\\s|$)")
    Regex.replace(pattern, value, "\\1" <> escape_replacement(replacement), global: false)
  end

  defp escape_replacement(text), do: String.replace(text, "\\", "\\\\")
end
