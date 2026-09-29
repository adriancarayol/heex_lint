defmodule HeexLint.Rules.NoUnknownClasses do
  @moduledoc """
  Catches class names that produce no CSS, by asking the project's own
  Tailwind v4 with its theme, custom utilities, variants and plugins. It
  suggests spelling corrections when it finds a close match.

      "flex-cols" is not a class this project's Tailwind knows, so no CSS is generated for it. Did you mean "flex-col"?

  Custom utilities and plain class selectors in the theme's import graph
  are known. Classes from stylesheets outside it need an `allow` entry.
  A class the grammar reads as a color is left to `no_raw_colors` when it
  names a token or misspells one.

  Without a Tailwind to ask (see `HeexLint.Tailwind`), the class grammar,
  `@utility` names and class selectors answer instead; that checks less.

  ## Options

    * `:allow`, `:deny`, `:contracts` - exceptions; entries may name
      external classes, so they are not validated.
    * `:message` - replaces the text. Also `{{suggestion}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Messages, Policy, Rule, Tailwind, Theme}
  alias HeexLint.Grammar.{Classes, ProjectClassifier, Similar}
  alias HeexLint.Policy.ConfigError
  alias HeexLint.Rules.NoRawColors

  @messages %{
    unknown_class:
      ~s|"{{className}}" is not a class this project's Tailwind knows, so no CSS is generated for it. Fix the spelling, or declare it with @utility in {{file}}.|,
    unknown_class_suggest:
      ~s|"{{className}}" is not a class this project's Tailwind knows, so no CSS is generated for it. Did you mean "{{suggestion}}"?|,
    unknown_variant:
      ~s|"{{className}}" uses a variant this project's Tailwind does not know, so no CSS is generated for it. Use an existing variant, or declare it with @custom-variant in {{file}}.|,
    use_suggestion: ~s|Replace with "{{suggestion}}".|
  }

  @impl true
  def name, do: :no_unknown_classes

  @impl true
  def prepare(options, project) do
    {policy, warnings} =
      Policy.compile(
        Keyword.put(options, :unchecked_entries, true),
        project.theme,
        "no_unknown_classes"
      )

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

    # A template's colocated CSS declares classes for the file the way the
    # theme does for everything.
    own =
      for {_template, elements} <- file.elements,
          element <- elements,
          HeexLint.Element.colocated_css?(element),
          class <- Theme.parse_class_selectors(element.text || ""),
          into: MapSet.new(),
          do: class

    candidates =
      for {site, string} <-
            NoRawColors.class_strings(file, Keyword.delete(options, :scan_all_strings)),
          {token, position} <- Rule.tokens(string),
          not settled?(theme, own, token),
          (exemption = Policy.decide(policy, site && site.component, token)) != :ok,
          do: {site, string, token, position, elem(exemption, 3)}

    asked = Tailwind.unknown(project, Enum.map(candidates, &elem(&1, 2)))

    if asked do
      by_token = Map.new(asked, &{&1.token, &1})

      for {site, string, token, position, words} <- candidates,
          %{suggestion: suggestion, base_known: base_known} <- List.wrap(Map.get(by_token, token)),
          not (color?(theme, token) and not base_known and
                 not owns_color_typo?(theme, token, suggestion)) do
        report(
          token,
          position,
          string,
          suggestion,
          words,
          site,
          base_known and String.contains?(token, ":"),
          theme_file,
          options,
          file
        )
      end
    else
      for {site, string, token, position, words} <- candidates,
          not known_by_grammar?(theme, token) do
        report(token, position, string, nil, words, site, false, theme_file, options, file)
      end
    end
  end

  defp report(
         token,
         position,
         string,
         suggestion,
         words,
         site,
         variant_only,
         theme_file,
         options,
         file
       ) do
    id =
      cond do
        suggestion -> :unknown_class_suggest
        variant_only -> :unknown_variant
        true -> :unknown_class
      end

    data = %{
      "className" => token,
      "component" => Rule.display(site && site.component),
      "file" => theme_file,
      "suggestion" => suggestion || ""
    }

    %{
      position: position,
      message: Rule.message(@messages[id], data, words, options, file),
      suggestions:
        if(suggestion,
          do:
            Rule.suggestions(
              string,
              token,
              [suggestion],
              &Messages.interpolate(@messages.use_suggestion, %{"suggestion" => &1})
            ),
          else: []
        )
    }
  end

  # What the project's CSS settles without asking Tailwind.
  defp settled?(theme, own, token) do
    base = Classes.normalize(token)
    bare = String.replace(base, ~r/\/[\w.%]+$/, "")

    base == "" or String.starts_with?(base, "[") or Classes.marker?(token) or
      MapSet.member?(theme.classes, bare) or MapSet.member?(own, bare)
  end

  # Without Tailwind: the grammar plus @utility names.
  defp known_by_grammar?(theme, token) do
    bare = token |> Classes.normalize() |> String.replace(~r/\/[\w.%]+$/, "")

    ProjectClassifier.group_of(theme, token) != nil or MapSet.member?(theme.utilities, bare) or
      Enum.any?(Theme.utility_prefixes(theme.utilities), &String.starts_with?(bare, &1))
  end

  defp color?(theme, token), do: ProjectClassifier.category_of(theme, token) == "color"

  # An undeclared token or a near-miss of one is no_raw_colors' finding; a
  # typo of another utility (text-smal) is this rule's.
  defp owns_color_typo?(_theme, _token, nil), do: false

  defp owns_color_typo?(theme, token, suggestion) do
    if color?(theme, suggestion) do
      false
    else
      case NoRawColors.split_color_class(token) do
        nil ->
          true

        %{value: value} ->
          declared = Theme.color_tokens(theme)
          declared == nil or Similar.did_you_mean(value, declared) == nil
      end
    end
  end
end
