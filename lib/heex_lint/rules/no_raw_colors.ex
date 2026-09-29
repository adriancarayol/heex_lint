defmodule HeexLint.Rules.NoRawColors do
  @moduledoc """
  Reports colors from Tailwind's default palette, such as `bg-zinc-100` or `text-white`.

  Raw palette colors skip the theme, so they don't follow its tokens or its dark
  mode. The message suggests the theme colors that look closest.

  A palette color the theme defines itself in `@theme` (`--color-zinc-100`) is allowed.

  ## Options

    * `:allow` - classes to allow, as patterns such as `"text-white"` or `"*-black/50"`.
    * `:message` - a custom message. Placeholders: `{{class}}`, `{{suggestion}}`, `{{theme}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{ClassName, Palette, Rule, Suggest, Theme}

  @prefixes ~w(
    bg text border border-x border-y border-s border-e border-t border-r border-b border-l
    divide outline ring ring-offset inset-ring shadow inset-shadow drop-shadow text-shadow
    decoration accent caret fill stroke from via to placeholder
  )

  @pattern_source "^(#{Enum.join(Enum.sort_by(@prefixes, &(-String.length(&1))), "|")})-(#{Enum.join(Palette.names(), "|")})(?:-(\\d+))?(?:/[\\w.\\[\\]%-]+)?$"

  @impl true
  def name, do: :no_raw_colors

  @impl true
  def check(element, context) do
    pattern = Regex.compile!(@pattern_source)

    for {:static, raw, position} <- Rule.class_tokens(element, context),
        not Rule.allowed?(raw, context.options),
        class = ClassName.parse(raw),
        {prefix, color, value} <- raw_color(class.utility, pattern),
        not Theme.theme_color?(context.theme, color) do
      suggestion = Suggest.colors(class, prefix, value, context, opacity(class.utility))

      default =
        "\"#{raw}\" is a raw Tailwind palette color, so it ignores the theme and its dark mode. #{suggestion}"

      {position,
       Rule.message(context, default,
         class: raw,
         suggestion: suggestion,
         theme: Rule.theme_file(context)
       )}
    end
  end

  defp opacity(utility) do
    case Regex.run(~r{/[^/]+$}, utility) do
      [modifier] -> modifier
      nil -> ""
    end
  end

  defp raw_color(utility, pattern) do
    with [_ | parts] <- Regex.run(pattern, utility),
         [prefix, name | shade] = parts,
         color = Enum.join([name | shade], "-"),
         value when is_binary(value) <- Palette.value(color) do
      [{prefix, color, value}]
    else
      _ -> []
    end
  end
end
