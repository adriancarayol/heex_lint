defmodule HeexLint.Rules.NoUnknownVariables do
  @moduledoc """
  Reports classes that read a CSS variable the theme does not define, such
  as `bg-(--surfce)` or `text-[var(--ink-2)]`. Tailwind still emits CSS for
  them, but the value is empty, so the class silently does nothing.

  A HeexLint addition: @shadcn/lint's rules let variable references pass
  without checking them. Variables set in any template's `style` attribute
  (`style="--progress: 40%"`) count as defined, and so does every custom
  property in the theme's import graph, dark mode included. Skipped when
  no theme is found.

  ## Options

    * `:allow` - variable names to allow, as patterns such as `"--radix-*"`.
    * `:message` - replaces the text. Also `{{variable}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Rule, Theme}
  alias HeexLint.Grammar.Similar

  @message ~s|"{{className}}" reads {{variable}}, which {{file}} does not define, so the class has no effect.{{suggestion}}|

  @impl true
  def name, do: :no_unknown_variables

  @impl true
  def prepare(options, project) do
    allow =
      options
      |> Keyword.get(:allow, [])
      |> Enum.map(fn
        %Regex{} = regex ->
          regex

        glob ->
          Regex.compile!("^" <> (glob |> Regex.escape() |> String.replace("\\*", ".*")) <> "$")
      end)

    {:ok, %{allow: allow, inline: inline_variables(project)}, []}
  end

  @impl true
  def check(%{project: %{theme: %Theme{file: nil}}}, _state, _options), do: []

  def check(file, state, options) do
    theme = file.project.theme
    theme_file = Path.relative_to(file.project.theme_file, file.project.root)

    for site <- file.sites,
        site.kind == :class,
        string <- site.strings,
        {token, position} <- Rule.tokens(string),
        [_, variable] <- Regex.scan(~r/(?:\(|var\()(--[\w-]+)\)/, token),
        not defined?(theme, state, variable) do
      suggestion =
        case Similar.did_you_mean(variable, Enum.map(theme.variables, &("--" <> &1)), 2) do
          nil -> ""
          meant -> " Did you mean #{meant}?"
        end

      data = %{
        "className" => token,
        "variable" => variable,
        "file" => theme_file,
        "suggestion" => suggestion
      }

      %{position: position, message: Rule.message(@message, data, nil, options, file)}
    end
  end

  defp defined?(theme, state, variable) do
    Theme.variable?(theme, variable) or MapSet.member?(state.inline, variable) or
      Enum.any?(state.allow, &Regex.match?(&1, variable))
  end

  # CSS variables set in `style` attributes anywhere in the project.
  defp inline_variables(project) do
    for {_path, source} <- project.sources,
        template <- source.templates,
        {:ok, elements} <- [HeexLint.Template.elements(template)],
        element <- elements,
        %{name: "style", value: {kind, text, _}} <- element.attributes,
        kind in [:string, :expr],
        [variable] <- Regex.scan(~r/--[\w-]+(?=\s*:)/, text),
        into: MapSet.new(),
        do: variable
  end
end
