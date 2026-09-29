defmodule HeexLint.Rules.NoArbitraryValues do
  @moduledoc """
  Use theme tokens and scale values instead of values such as `p-[13px]` or
  `rounded-[10px]`. Arbitrary values are reported even when an equivalent
  token or scale step exists, and that equivalent is suggested.

      "p-[13px]" hardcodes an off-token value. Use "p-3.25" instead (same value, on the scale).

  Arbitrary variants (`data-[state=open]:flex`, `[&_svg]:size-4`) and
  variable shorthands (`bg-(--brand)`) are not arbitrary values. An
  arbitrary property such as `[padding:13px]` is.

  Start with layout allowed: `no_arbitrary_values: {:error, allow: ["layout"]}`.

  ## Options

    * `:allow`, `:deny`, `:contracts` - exceptions. See `HeexLint.Policy`.
    * `:message` - replaces the text. Also `{{replacement}}` and `{{tokens}}`.
    * `:scan_all_strings` - check every string literal in the file.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Messages, Policy, Rule, Suggest, Theme}
  alias HeexLint.Grammar.{Classes, Lengths, ProjectClassifier, Categories}
  alias HeexLint.Policy.ConfigError
  alias HeexLint.Rules.NoRawColors

  # Layout groups on the spacing scale, so w-[200px] is named as w-50.
  @spacing_groups MapSet.new(~w(
    m mx my ms me mt mr mb ml w min-w max-w h min-h max-h size inset inset-x inset-y
    start end top right bottom left translate translate-x translate-y basis indent leading
    scroll-m scroll-mx scroll-my scroll-mt scroll-mr scroll-mb scroll-ml
    scroll-p scroll-px scroll-py scroll-pt scroll-pr scroll-pb scroll-pl
  ))

  @messages %{
    arbitrary_value:
      ~s|"{{className}}" hardcodes an off-token value. Use a theme token or scale value instead.|,
    arbitrary_value_with_scale:
      ~s|"{{className}}" hardcodes an off-token value. Use "{{replacement}}" instead (same value, on the scale).|,
    arbitrary_value_near_scale:
      ~s|"{{className}}" hardcodes an off-token value. Nearest on the scale: {{suggestions}}.|,
    arbitrary_color_near:
      ~s|"{{className}}" hardcodes a color. Nearest theme tokens: {{suggestions}}. Use one of those, or declare --color-<name> in {{file}}.|,
    arbitrary_color_far:
      ~s|"{{className}}" hardcodes a color and no declared theme color is close to it. Use one of: {{tokens}}, or declare --color-<name> in {{file}}.|,
    use_scale: ~s|Replace with "{{replacement}}" (same value, on the scale).|,
    use_token: ~s|Replace with "{{replacement}}".|,
    use_variable: ~s|Replace with "{{replacement}}" (the variable shorthand).|
  }

  @impl true
  def name, do: :no_arbitrary_values

  @impl true
  def prepare(options, project) do
    {policy, warnings} = Policy.compile(options, project.theme, "no_arbitrary_values")
    {:ok, policy, warnings}
  rescue
    error in ConfigError -> {:error, error.message}
  end

  @impl true
  def check(file, policy, options) do
    project = file.project
    theme = project.theme

    theme_file =
      if project.theme_file,
        do: Path.relative_to(project.theme_file, project.root),
        else: "your theme CSS"

    for {site, string} <- NoRawColors.class_strings(file, options),
        {token, position} <- Rule.tokens(string),
        Classes.arbitrary_value?(token),
        (exemption = Policy.decide(policy, site && site.component, token)) != :ok do
      words = elem(exemption, 3)

      finding(
        token,
        position,
        string,
        site && site.component,
        theme,
        theme_file,
        words,
        options,
        file
      )
    end
  end

  defp finding(token, position, string, component, theme, theme_file, words, options, file) do
    group = ProjectClassifier.group_of(theme, token)
    category = Categories.category_of(group)
    parts = split_arbitrary(token)
    display = Rule.display(component)

    color = if category == "color" and parts, do: color_suggestions(token, parts, theme)

    if color do
      id = if color == [], do: :arbitrary_color_far, else: :arbitrary_color_near

      data = %{
        "className" => token,
        "component" => display,
        "suggestions" => Enum.join(color, ", "),
        "tokens" => Messages.list_tokens(Theme.color_tokens(theme) || []),
        "file" => theme_file
      }

      %{
        position: position,
        message: Rule.message(@messages[id], data, words, options, file),
        suggestions:
          Rule.suggestions(
            string,
            token,
            color,
            &Messages.interpolate(@messages.use_token, %{"replacement" => &1})
          )
      }
    else
      scale_kind =
        cond do
          group == "font-size" -> :text
          group && Regex.match?(~r/^rounded(-|$)/, group) -> :radius
          true -> nil
        end

      {replacement, near} =
        cond do
          category == "spacing" or (group && MapSet.member?(@spacing_groups, group)) ->
            {scale_equivalent(token, theme.spacing), nil}

          scale_kind && parts ->
            px = Lengths.px(String.replace(parts.inner, "_", " "))

            steps =
              if px == nil,
                do: [],
                else: Suggest.nearest_steps(px, Theme.scale(theme, scale_kind))

            to_class = fn name ->
              Classes.with_base(token, "#{parts.utility}-#{name}#{parts.suffix}")
            end

            case steps do
              [%{exact: true, name: name} | _] -> {to_class.(name), nil}
              [] -> {nil, nil}
              steps -> {nil, Suggest.format_steps(steps, to_class)}
            end

          true ->
            {nil, nil}
        end

      id =
        cond do
          replacement -> :arbitrary_value_with_scale
          near -> :arbitrary_value_near_scale
          true -> :arbitrary_value
        end

      data = %{
        "className" => token,
        "component" => display,
        "replacement" => replacement || "",
        "suggestions" => near || "",
        "file" => theme_file
      }

      suggestions =
        cond do
          replacement ->
            Rule.suggestions(
              string,
              token,
              [replacement],
              &Messages.interpolate(@messages.use_scale, %{"replacement" => &1}),
              # A font size step also sets a line height, so only spacing
              # and radius steps generate the same CSS.
              exact: scale_kind != :text
            )

          shorthand = parts && variable_shorthand(token, parts) ->
            Rule.suggestions(
              string,
              token,
              [shorthand],
              &Messages.interpolate(@messages.use_variable, %{"replacement" => &1}),
              exact: true
            )

          true ->
            []
        end

      %{
        position: position,
        message: Rule.message(@messages[id], data, words, options, file),
        suggestions: suggestions
      }
    end
  end

  # A HeexLint addition: bg-[var(--brand)] names a variable the way the
  # shorthand bg-(--brand) does, which is not an arbitrary value.
  defp variable_shorthand(token, parts) do
    case Regex.run(~r/^(?:([a-z-]+):)?var\((--[\w-]+)\)$/, parts.inner) do
      [_, "", variable] ->
        Classes.with_base(token, "#{parts.utility}-(#{variable})#{parts.suffix}")

      [_, hint, variable] ->
        Classes.with_base(token, "#{parts.utility}-(#{hint}:#{variable})#{parts.suffix}")

      nil ->
        nil
    end
  end

  # Nil when the theme's values cannot be read.
  defp color_suggestions(token, parts, theme) do
    lab = Suggest.arbitrary_color(parts.inner)
    colors = if lab, do: Theme.color_values(theme)

    if lab && colors && map_size(colors) > 0 do
      lab
      |> Suggest.nearest_color_tokens(colors, Suggest.role(parts.utility <> "-"))
      |> Enum.map(&Classes.with_base(token, "#{parts.utility}-#{&1}#{parts.suffix}"))
    end
  end

  @doc """
  "rounded-tl-[10px]" as utility "rounded-tl", inner "10px", suffix "".
  """
  def split_arbitrary(token) do
    case Regex.run(~r/^(.+?)-\[([^\]]*)\](.*)$/, Classes.normalize(token)) do
      [_, utility, inner, suffix] -> %{utility: utility, inner: inner, suffix: suffix}
      nil -> nil
    end
  end

  @doc """
  p-[13px] as p-3.25, when it lands on a quarter step of the spacing unit.

      iex> HeexLint.Rules.NoArbitraryValues.scale_equivalent("md:-mt-[12px]", 4.0)
      "md:-mt-3"
  """
  def scale_equivalent(_token, nil), do: nil

  def scale_equivalent(token, unit) do
    {variants, base} = Classes.split_variants(token)
    leading = if String.starts_with?(base, "!"), do: "!", else: ""
    trailing = if leading == "" and String.ends_with?(base, "!"), do: "!", else: ""

    bare =
      base
      |> String.slice(String.length(leading)..-1//1)
      |> String.slice(0, String.length(base) - String.length(leading) - String.length(trailing))

    with [_, negative, utility, px] <-
           Regex.run(~r/^(-?)([a-z]+(?:-[a-z]+)*)-\[(\d+(?:\.\d+)?)px\]$/, bare),
         {px, ""} <- Float.parse(px),
         steps = px / unit,
         true <- steps * 4 == Float.round(steps * 4) do
      prefix = if variants == [], do: "", else: Enum.join(variants, ":") <> ":"
      "#{prefix}#{leading}#{negative}#{utility}-#{number(steps)}#{trailing}"
    else
      _ -> nil
    end
  end

  defp number(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp number(n), do: n |> Float.round(4) |> Float.to_string()
end
