defmodule HeexLint.Rules.NoRawColors do
  @moduledoc """
  Use colors from your theme. Reports raw Tailwind palette colors,
  undeclared color tokens, and literal colors in SVG attributes, and
  suggests nearby theme colors when it can resolve their values.

  Tokens are the `--color-*` declarations in `@theme` (and a utility's own
  namespace, such as `--background-color-surface` for `bg-surface`). Given a
  theme that declares `primary`:

      <div class="bg-primary">   allowed
      <div class="bg-pink-500">  "bg-pink-500" uses the raw Tailwind palette...
      <div class="bg-highlight"> "bg-highlight" is not a declared theme color...
      <path fill="#ec4899" />    fill="#ec4899" hardcodes a color...

  `white`, `black`, `transparent`, `current` and `inherit` are accepted.
  Arbitrary colors such as `bg-[#333]` belong to `no_arbitrary_values`.

  ## Options

    * `:allow`, `:deny`, `:contracts` - exceptions, as class patterns
      (`*-amber-*`), groups or categories. See `HeexLint.Policy`.
    * `:message` - replaces the text. Also `{{tokens}}` and `{{suggestion}}`.
    * `:scan_all_strings` - check every string literal in the file.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Collector, Messages, Policy, Rule, Suggest, Theme}
  alias HeexLint.Grammar.{Categories, Classes, Colors, ProjectClassifier, Similar}
  alias HeexLint.Policy.ConfigError

  @named MapSet.new(~w(white black transparent current inherit))

  # HTML and SVG attributes that take a color directly.
  @color_attributes MapSet.new(~w(
    fill stroke color stopColor floodColor lightingColor stop-color flood-color lighting-color
  ))

  # Attribute values that defer to the cascade or to a token.
  @attribute_allowed MapSet.new(
                       ~w(currentColor currentcolor none inherit transparent initial unset)
                     )

  @color_function ~r/^(?:#[0-9a-fA-F]{3,8}|(?:rgb|rgba|hsl|hsla|hwb|oklch|oklab|lab|lch|color|color-mix)\(.*\))$/

  @prefix_namespaces %{
    "bg" => "background-color",
    "text" => "text-color",
    "border" => "border-color",
    "divide" => "divide-color",
    "ring" => "ring-color",
    "outline" => "outline-color",
    "accent" => "accent-color",
    "caret" => "caret-color",
    "placeholder" => "placeholder-color",
    "decoration" => "text-decoration-color",
    "text-shadow" => "text-shadow-color",
    "drop-shadow" => "drop-shadow-color",
    "fill" => "fill",
    "stroke" => "stroke"
  }

  @messages %{
    palette_class:
      ~s|"{{className}}" uses the raw Tailwind palette. Use a theme token, or define one for this color.|,
    palette_class_near:
      ~s|"{{className}}" uses the raw Tailwind palette. Nearest theme tokens: {{suggestions}}. Use one of those, or declare --color-<name> in {{file}} for a new color.|,
    palette_class_far:
      ~s|"{{className}}" uses the raw Tailwind palette and no declared theme color is close to it. Use one of: {{tokens}}, or declare --color-<name> in {{file}} for a new color.|,
    palette_class_listed:
      ~s|"{{className}}" uses the raw Tailwind palette. Use one of the theme colors: {{tokens}}, or declare --color-<name> in {{file}} for a new color.|,
    undeclared_token:
      ~s|"{{className}}" is not a declared theme color. Use one of: {{tokens}}. To add a color, declare --color-<name> in {{file}} first.|,
    undeclared_token_typo:
      ~s|"{{className}}" is not a declared theme color. Did you mean "{{suggestion}}"? Declared colors: {{tokens}}.|,
    raw_color_attribute:
      ~s|{{attribute}}="{{value}}" hardcodes a color. Use currentColor with a text color class, or var(--color-<token>).|,
    raw_color_attribute_near:
      ~s|{{attribute}}="{{value}}" hardcodes a color. Use currentColor with a text color class, or the nearest theme token: var(--color-{{suggestion}}).|,
    use_token: ~s|Replace with "{{replacement}}".|
  }

  @impl true
  def name, do: :no_raw_colors

  @impl true
  def prepare(options, project) do
    {policy, warnings} = Policy.compile(options, project.theme, "no_raw_colors")
    {:ok, policy, warnings}
  rescue
    error in ConfigError -> {:error, error.message}
  end

  @impl true
  def check(file, policy, options) do
    theme = file.project.theme
    context = %{project: file.project, theme: theme, file: theme_file(file.project)}

    class_findings =
      for {site, string} <- class_strings(file, options),
          {token, position} <- Rule.tokens(string),
          verdict = verdict(context, token),
          verdict != nil,
          (exemption = Policy.decide(policy, site_component(site), token)) != :ok do
        data = Map.put(verdict.data, "component", Rule.display(site_component(site)))

        %{
          position: position,
          message: Rule.message(@messages[verdict.id], data, words(exemption), options, file),
          suggestions:
            Rule.suggestions(string, token, verdict[:replacements] || [], fn replacement ->
              Messages.interpolate(@messages.use_token, %{"replacement" => replacement})
            end)
        }
      end

    class_findings ++ attribute_findings(file, context, options)
  end

  defp words({_, _, _, message}), do: message
  defp words(_), do: nil

  defp site_component(%{component: component}), do: component
  defp site_component(_), do: nil

  @doc false
  # The class strings of the file's sites, or every string literal with
  # scan_all_strings.
  def class_strings(file, options) do
    sites =
      for site <- file.sites, site.kind == :class, string <- site.strings, do: {site, string}

    if Keyword.get(options, :scan_all_strings, false),
      do: sites ++ Enum.map(all_strings(file), &{nil, &1}),
      else: sites
  end

  @doc false
  def all_strings(file) do
    source = file.source

    code_strings =
      if source.ast do
        {_, strings} =
          Macro.prewalk(source.ast, [], fn
            {:sigil_H, _, _}, acc ->
              {nil, acc}

            {:__block__, _, [text]} = node, acc when is_binary(text) ->
              context = %{project: file.project, source: source}
              {node, acc ++ Collector.expression(node, context).strings}

            node, acc ->
              {node, acc}
          end)

        strings
      else
        []
      end

    template_strings =
      for {template, elements} <- file.elements,
          element <- elements,
          %{value: {:string, _, _} = value} <- element.attributes,
          string <-
            Collector.attribute(value, %{
              project: file.project,
              source: source,
              template: template
            }).strings,
          do: string

    code_strings ++ template_strings
  end

  defp theme_file(%{theme_file: nil}), do: "your theme CSS"
  defp theme_file(%{theme_file: file, root: root}), do: Path.relative_to(file, root)

  ## Verdicts

  defp verdict(context, token) do
    key = {__MODULE__, context.theme && context.theme.file, token}

    case Process.get(key, :miss) do
      :miss ->
        verdict = judge(context, token)
        Process.put(key, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  defp judge(context, token) do
    theme = context.theme
    declared = Theme.color_tokens(theme)
    parts = split_color_class(token)
    value = parts && parts.value

    cond do
      Classes.arbitrary_value?(token) -> nil
      # A palette name the theme declares is one of its tokens.
      value && declared && MapSet.member?(declared, value) -> nil
      # --background-color-surface declares bg-surface, and only that.
      parts && member?(tokens_for(theme, parts.prefix), value) -> nil
      Classes.palette_class?(token) -> palette_verdict(context, token)
      declared == nil -> nil
      ProjectClassifier.category_of(theme, token) != "color" -> nil
      value == nil or MapSet.member?(@named, value) -> nil
      # A class the project's CSS declares with @utility is its vocabulary.
      Theme.declares_utility?(theme, token) -> nil
      true -> undeclared_verdict(context, token)
    end
  end

  defp member?(nil, _value), do: false
  defp member?(set, value), do: MapSet.member?(set, value)

  defp palette_verdict(context, token) do
    declared = Theme.color_tokens(context.theme)
    values = Theme.color_values(context.theme)

    cond do
      declared == nil ->
        %{id: :palette_class, data: %{"className" => token}}

      values == nil or map_size(values) == 0 ->
        %{
          id: :palette_class_listed,
          data: %{
            "className" => token,
            "tokens" => Messages.list_tokens(declared),
            "file" => context.file
          }
        }

      true ->
        suggestions = nearest(token, values)

        %{
          id: if(suggestions == [], do: :palette_class_far, else: :palette_class_near),
          data: %{
            "className" => token,
            "suggestions" => Enum.join(suggestions, ", "),
            "tokens" => Messages.list_tokens(declared),
            "file" => context.file
          },
          replacements: suggestions
        }
    end
  end

  defp nearest(token, values) do
    with %{prefix: prefix, value: value, opacity: opacity} <- split_color_class(token),
         lab when lab != nil <- Suggest.palette_color(value) do
      lab
      |> Suggest.nearest_color_tokens(values, Suggest.role(prefix))
      |> Enum.map(&Classes.with_base(token, prefix <> &1 <> opacity))
    else
      _ -> []
    end
  end

  defp undeclared_verdict(context, token) do
    declared = Theme.color_tokens(context.theme)
    parts = split_color_class(token)
    tokens = parts && tokens_for(context.theme, parts.prefix)
    meant = parts && tokens && Similar.did_you_mean(parts.value, tokens)

    cond do
      meant ->
        suggestion = Classes.with_base(token, parts.prefix <> meant <> parts.opacity)

        %{
          id: :undeclared_token_typo,
          data: %{
            "className" => token,
            "suggestion" => suggestion,
            "tokens" => Messages.list_tokens(declared),
            "file" => context.file
          },
          replacements: [suggestion]
        }

      typo_of_another_utility?(context, token) ->
        nil

      true ->
        %{
          id: :undeclared_token,
          data: %{
            "className" => token,
            "tokens" => Messages.list_tokens(declared),
            "file" => context.file
          }
        }
    end
  end

  # cn's color groups take any value, so text-smal classifies as a color.
  # When Tailwind's nearest real class is not a color, the typo belongs to
  # no_unknown_classes and this rule stays quiet.
  defp typo_of_another_utility?(context, token) do
    case HeexLint.Tailwind.unknown(context.project, [token]) do
      [%{suggestion: suggestion} | _] when is_binary(suggestion) ->
        ProjectClassifier.category_of(context.theme, suggestion) != "color"

      _ ->
        false
    end
  end

  # The tokens this utility can name: --color-* plus its own namespace.
  defp tokens_for(theme, prefix) do
    declared = Theme.color_tokens(theme)

    own =
      case color_namespace(prefix) do
        nil -> nil
        namespace -> Map.get(theme.scoped, namespace)
      end

    cond do
      own == nil or MapSet.size(own) == 0 -> declared
      true -> MapSet.union(declared || MapSet.new(), own)
    end
  end

  @doc false
  # "hover:bg-zinc-100/50" as prefix "bg-", value "zinc-100", opacity "/50".
  def split_color_class(token) do
    base = Classes.normalize(token)

    case Regex.run(Classes.color_prefix(), base) do
      [prefix] ->
        rest = String.slice(base, String.length(prefix)..-1//1)

        opacity =
          case Regex.run(Classes.opacity_modifier(), rest) do
            [match | _] -> match
            nil -> ""
          end

        value = String.slice(rest, 0, String.length(rest) - String.length(opacity))

        if value == "" or String.starts_with?(value, "[") or String.starts_with?(value, "("),
          do: nil,
          else: %{prefix: prefix, value: value, opacity: opacity}

      nil ->
        nil
    end
  end

  # The @theme namespace a color utility reads before --color-*.
  defp color_namespace(prefix) do
    base = String.replace_suffix(prefix, "-", "")

    Map.get(@prefix_namespaces, base) ||
      Map.get(@prefix_namespaces, String.replace(base, ~r/-(?:[trblxyse]|[bi][se])$/, ""))
  end

  ## SVG and HTML color attributes

  defp attribute_findings(file, context, options) do
    values = Theme.color_values(context.theme)

    for {_template, elements} <- file.elements,
        element <- elements,
        element.type == :tag,
        Regex.match?(~r/^[a-z]/, element.name),
        %{name: name, value: {:string, value, position}} <- element.attributes,
        is_binary(name) and MapSet.member?(@color_attributes, name),
        raw_color_value?(value) do
      lab = if values && map_size(values) > 0, do: Colors.parse(value)

      suggestion =
        if lab, do: lab |> Suggest.nearest_color_tokens(values, :text, 1) |> List.first()

      id = if suggestion, do: :raw_color_attribute_near, else: :raw_color_attribute
      data = %{"attribute" => name, "value" => value, "suggestion" => suggestion || ""}
      # Attribute findings report at the value, like the class ones.
      %{position: position, message: Rule.message(@messages[id], data, nil, options, file)}
    end
  end

  @doc false
  def raw_color_value?(value) do
    trimmed = String.trim(value)

    cond do
      MapSet.member?(@attribute_allowed, trimmed) -> false
      Regex.match?(@color_function, trimmed) -> true
      true -> Colors.named_color?(trimmed)
    end
  end

  @doc false
  def categories, do: Categories.categories()
end
