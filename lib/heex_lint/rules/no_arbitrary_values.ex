defmodule HeexLint.Rules.NoArbitraryValues do
  @moduledoc """
  Reports arbitrary values such as `p-[13px]`, `text-[11px]`, `bg-[#fff]` and
  arbitrary properties such as `[mask-type:alpha]`.

  The message suggests the matching scale value when there is one
  (`p-[12px]` → `p-3`), the nearest font size or radius, or the closest theme
  color.

  References to CSS variables (`bg-(--surface)`, `bg-[var(--surface)]`) are
  theme values, not arbitrary ones, and are allowed; `no_unknown_variables`
  checks that they exist.

  ## Options

    * `:allow` - classes to allow, as patterns such as `"grid-cols-[*"]`.
    * `:variants` - also report arbitrary variants such as `[&>svg]:size-4` (default `false`).
    * `:message` - a custom message. Placeholders: `{{class}}`, `{{suggestion}}`, `{{theme}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{ClassName, Rule, Suggest}

  @spacing ~w(
    p px py pt pr pb pl ps pe m mx my mt mr mb ml ms me gap gap-x gap-y space-x space-y
    w h size min-w min-h max-w max-h inset inset-x inset-y top right bottom left start end
    translate-x translate-y scroll-m scroll-p indent basis
  )

  @font_sizes [
    {"xs", 12},
    {"sm", 14},
    {"base", 16},
    {"lg", 18},
    {"xl", 20},
    {"2xl", 24},
    {"3xl", 30},
    {"4xl", 36},
    {"5xl", 48},
    {"6xl", 60},
    {"7xl", 72},
    {"8xl", 96},
    {"9xl", 128}
  ]

  @radii [
    {"xs", 2},
    {"sm", 4},
    {"md", 6},
    {"lg", 8},
    {"xl", 12},
    {"2xl", 16},
    {"3xl", 24},
    {"4xl", 32}
  ]

  @color_prefixes ~w(bg text border outline ring fill stroke decoration accent caret from via to divide shadow)

  @impl true
  def name, do: :no_arbitrary_values

  @impl true
  def check(element, context) do
    for {:static, raw, position} <- Rule.class_tokens(element, context),
        not Rule.allowed?(raw, context.options),
        class = ClassName.parse(raw),
        arbitrary?(class, context.options) do
      suggestion = suggestion(class, context)

      default =
        "\"#{raw}\" uses an arbitrary value, which skips the design system's scale. #{suggestion}"

      {position,
       Rule.message(context, default,
         class: raw,
         suggestion: suggestion,
         theme: Rule.theme_file(context)
       )}
    end
  end

  defp arbitrary?(%ClassName{} = class, options) do
    arbitrary_utility?(class.utility) or
      (Keyword.get(options, :variants, false) and
         Enum.any?(class.variants, &String.contains?(&1, "[")))
  end

  defp arbitrary_utility?(utility) do
    String.contains?(utility, "[") and not variable_reference?(utility)
  end

  # `bg-[var(--x)]` and `text-[length:var(--x)]` point at a theme variable.
  defp variable_reference?(utility),
    do: Regex.match?(~r/-\[(?:[a-z-]+:)?var\(--[\w-]+\)\](?:\/.*)?$/, utility)

  defp suggestion(class, context) do
    case Regex.run(~r/^(.+?)-\[(.+)\]$/, class.utility) do
      [_, prefix, value] ->
        suggest(prefix, value, class, context)

      nil ->
        "Use a Tailwind utility, or add a @utility to #{Rule.theme_file(context)} if the design needs a new one."
    end
  end

  defp suggest(prefix, value, class, context) when prefix in @spacing do
    case pixels(value) do
      nil ->
        generic(context)

      px ->
        steps = px / 4

        cond do
          px == 1 ->
            "Use #{ClassName.with_utility(class, "#{prefix}-px")}."

          round(steps * 4) == steps * 4 ->
            "Use the spacing scale: #{ClassName.with_utility(class, "#{prefix}-#{number(steps)}")} (#{number(px)}px)."

          true ->
            # Tailwind v4 accepts any multiple of 0.25 as a spacing step.
            lower = Float.floor(steps * 4) / 4
            upper = Float.ceil(steps * 4) / 4

            "Use the spacing scale: #{ClassName.with_utility(class, "#{prefix}-#{number(lower)}")} (#{number(lower * 4)}px) " <>
              "or #{ClassName.with_utility(class, "#{prefix}-#{number(upper)}")} (#{number(upper * 4)}px)."
        end
    end
  end

  defp suggest("text", value, class, context) do
    cond do
      px = pixels(value) -> nearest("text", @font_sizes, px, class, "font size")
      color?(value) -> Suggest.colors(class, "text", value, context)
      true -> generic(context)
    end
  end

  defp suggest("rounded" <> _ = prefix, value, class, context) do
    case pixels(value) do
      nil -> generic(context)
      px -> nearest(prefix, @radii, px, class, "radius")
    end
  end

  defp suggest(prefix, value, class, context) when prefix in @color_prefixes do
    if color?(value), do: Suggest.colors(class, prefix, value, context), else: generic(context)
  end

  defp suggest(_prefix, _value, _class, context), do: generic(context)

  defp nearest(prefix, scale, px, class, label) do
    {name, size} = Enum.min_by(scale, fn {_, size} -> abs(size - px) end)
    "Use the nearest #{label}: #{ClassName.with_utility(class, "#{prefix}-#{name}")} (#{size}px)."
  end

  defp generic(context) do
    "Use a value from the theme, or add a token to #{Rule.theme_file(context)} if the design calls for a new one."
  end

  defp pixels(value) do
    case Regex.run(~r/^(-?\d*\.?\d+)(px|rem)$/, value) do
      [_, n, "px"] -> parse_number(n)
      [_, n, "rem"] -> parse_number(n) * 16
      nil -> nil
    end
  end

  defp parse_number(n), do: n |> Float.parse() |> elem(0)

  defp color?(value), do: Regex.match?(~r/^(#|rgb|hsl|oklch|oklab|color\()/i, value)

  defp number(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp number(n), do: n |> Float.round(2) |> Float.to_string()
end
