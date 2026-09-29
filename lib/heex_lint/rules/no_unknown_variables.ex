defmodule HeexLint.Rules.NoUnknownVariables do
  @moduledoc """
  Reports classes that read a CSS variable the theme doesn't define, such as
  `bg-(--surfce)` or `text-[var(--ink-2)]`. Tailwind still emits CSS for them,
  but the value is empty, so the class silently does nothing.

  Variables set in any template's `style` attribute (`style="--progress: 40%"`)
  count as defined. The rule is skipped when no theme file is found.

  ## Options

    * `:allow` - variable names to allow, as patterns such as `"--radix-*"`.
    * `:message` - a custom message. Placeholders: `{{class}}`, `{{variable}}`, `{{suggestion}}`, `{{theme}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Rule, Theme}

  @impl true
  def name, do: :no_unknown_variables

  @impl true
  def check(_element, %{theme: %Theme{file: nil}}), do: []

  def check(element, context) do
    for {:static, raw, position} <- Rule.class_tokens(element, context),
        [_, variable] <- Regex.scan(~r/(?:\(|var\()(--[\w-]+)\)/, raw),
        not defined?(variable, context) do
      suggestion = suggestion(variable, context)

      default =
        "\"#{raw}\" reads #{variable}, which #{Rule.theme_file(context)} doesn't define, so the class has no effect." <>
          suggestion

      {position,
       Rule.message(context, default,
         class: raw,
         variable: variable,
         suggestion: suggestion,
         theme: Rule.theme_file(context)
       )}
    end
  end

  defp defined?(variable, context) do
    Theme.variable?(context.theme, variable) or
      MapSet.member?(Map.get(context, :inline_variables, MapSet.new()), variable) or
      Rule.allowed?(variable, context.options)
  end

  defp suggestion(variable, context) do
    candidates = Map.keys(context.theme.variables)

    case Enum.max_by(candidates, &String.jaro_distance(&1, variable), fn -> nil end) do
      nil ->
        ""

      best ->
        if String.jaro_distance(best, variable) >= 0.85, do: " Did you mean #{best}?", else: ""
    end
  end
end
