defmodule HeexLint.Config do
  @moduledoc """
  Configuration, read from `.heex_lint.exs` in the project root.

      # .heex_lint.exs
      [
        inputs: ["lib/**/*.{ex,heex}"],
        settings: [
          theme: "assets/css/app.css",
          ui: "MyAppWeb.CoreComponents",
          note: "See DESIGN.md for design rules and approved exceptions."
        ],
        rules: [
          no_restyle: {:error, allow: ["layout"]},
          no_raw_colors: :error,
          no_arbitrary_values: {:error, allow: ["layout"]},
          no_inline_styles: :error,
          require_static_classes: :error,
          no_unknown_classes: :warning
        ],
        overrides: [
          [
            files: ["lib/my_app_web/components/**"],
            rules: [no_restyle: :off, no_arbitrary_values: :off, require_static_classes: :off]
          ]
        ]
      ]

  ## Rules

  Only the rules listed are enabled. A rule is `:error`, `:warning`, `:off`
  or `{severity, options}`. Without a `:rules` key (or without a config
  file), the recommended set above applies, component-directory override
  included.

  ## Overrides

  Each override applies its rules to files matching one of its `files`
  globs (relative to the project root), in order. An override that sets
  only a severity keeps the options set before it.

  ## Settings

  Shared by every rule; a rule's own option of the same name wins:

    * `:theme` - the Tailwind stylesheet; discovered when not set
    * `:ui` - module name prefixes of the design system
    * `:component_imports` / `:ignore_imports` - regexes on module names
      that are (or never are) the design system
    * `:merge_functions` - functions whose arguments contain classes
    * `:variant_functions` - functions whose map values contain classes
    * `:note` - text appended to every message
    * `:tailwind_bin` - the standalone Tailwind binary, when not in `_build/`
  """

  alias HeexLint.{Messages, Rules}

  @builtin [
    Rules.NoRestyle,
    Rules.NoRawColors,
    Rules.NoArbitraryValues,
    Rules.NoInlineStyles,
    Rules.NoUnknownClasses,
    Rules.RequireStaticClasses,
    Rules.NoUnknownVariables
  ]

  @recommended [
    no_restyle: {:error, allow: ["layout"]},
    no_raw_colors: :error,
    no_arbitrary_values: {:error, allow: ["layout"]},
    no_inline_styles: :error,
    require_static_classes: :error,
    no_unknown_classes: :warning,
    no_unknown_variables: :error
  ]

  @recommended_overrides [
    [
      files: ["**/components/**"],
      rules: [no_restyle: :off, no_arbitrary_values: :off, require_static_classes: :off]
    ]
  ]

  @default_inputs ["lib/**/*.{ex,exs,heex}"]
  @setting_keys [
    :theme,
    :ui,
    :component_imports,
    :ignore_imports,
    :merge_functions,
    :variant_functions,
    :note,
    :tailwind_bin
  ]
  @recognition_keys [
    :ui,
    :component_imports,
    :ignore_imports,
    :merge_functions,
    :variant_functions
  ]

  defstruct inputs: @default_inputs, settings: %{}, rules: [], overrides: [], warnings: []

  @type rule_setting :: {module(), :error | :warning | :off, keyword()}

  @type t :: %__MODULE__{
          inputs: [String.t()],
          settings: map(),
          rules: [rule_setting()],
          overrides: [%{files: [Regex.t()], rules: [{module(), atom() | nil, keyword() | nil}]}]
        }

  @doc "The built-in rule modules."
  def builtin_rules, do: @builtin

  @doc "The recommended rules."
  def recommended, do: @recommended

  @doc """
  Loads the config at `path`, falling back to the recommended set when it
  doesn't exist.
  """
  @spec load(String.t()) :: t()
  def load(path \\ ".heex_lint.exs") do
    options =
      if File.regular?(path) do
        {options, _binding} = Code.eval_file(path)
        options
      else
        []
      end

    new(options)
  end

  @doc """
  Builds a config from a keyword list.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    settings =
      options
      |> Keyword.get(:settings, [])
      |> Map.new()
      |> Map.merge(Map.new(Keyword.take(options, [:theme, :note])))

    for key <- Map.keys(settings), key not in @setting_keys do
      raise ArgumentError,
            "unknown heex_lint setting #{inspect(key)}; expected one of #{inspect(@setting_keys)}"
    end

    {settings, warnings} = validate_settings(settings)

    {rules, overrides} =
      case Keyword.fetch(options, :rules) do
        {:ok, rules} -> {rules, Keyword.get(options, :overrides, [])}
        :error -> {@recommended, Keyword.get(options, :overrides, @recommended_overrides)}
      end

    %__MODULE__{
      inputs: Keyword.get(options, :inputs, @default_inputs),
      settings: settings,
      rules: Enum.map(rules, &rule/1),
      overrides: Enum.map(overrides, &override/1),
      warnings: warnings
    }
  end

  @list_settings [:ui, :component_imports, :ignore_imports, :merge_functions, :variant_functions]

  # A setting of the wrong type is ignored with one warning, the way a
  # shared ESLint setting is, rather than failing the whole run.
  defp validate_settings(settings) do
    Enum.reduce(settings, {%{}, []}, fn {key, value}, {valid, warnings} ->
      cond do
        key in @list_settings and strings?(value) ->
          {Map.put(valid, key, List.wrap(value)), warnings}

        key in @list_settings ->
          {valid,
           warnings ++ ["settings.#{key} must be a string or a list of strings; it is ignored."]}

        is_binary(value) or value == nil ->
          {Map.put(valid, key, value), warnings}

        true ->
          {valid, warnings ++ ["settings.#{key} must be a string; it is ignored."]}
      end
    end)
  end

  defp strings?(value) when is_binary(value), do: true

  defp strings?(value) when is_list(value),
    do: Enum.all?(value, &(is_binary(&1) or is_struct(&1, Regex)))

  defp strings?(_), do: false

  defp rule({key, setting}) do
    module = module!(key)
    {severity, options} = normalize(setting)
    options = options || []
    validate_options!(module, options)
    {module, severity, options}
  end

  defp override(override) do
    override = Map.new(override)

    files =
      override
      |> Map.get(:files, [])
      |> List.wrap()
      |> Enum.map(&glob/1)

    rules =
      override
      |> Map.get(:rules, [])
      |> Enum.map(fn {key, setting} ->
        module = module!(key)
        {severity, options} = normalize(setting)
        if options, do: validate_options!(module, options)
        {module, severity, options}
      end)

    %{files: files, rules: rules}
  end

  defp module!(key) do
    Enum.find(@builtin, &(&1.name() == key)) ||
      if is_atom(key) and Code.ensure_loaded?(key) and function_exported?(key, :check, 3),
        do: key,
        else: raise(ArgumentError, "unknown heex_lint rule #{inspect(key)}")
  end

  defp normalize({severity, options}) when is_list(options), do: {severity(severity), options}
  defp normalize(severity), do: {severity(severity), nil}

  defp severity(severity) when severity in [:error, :warning, :off], do: severity
  defp severity(:warn), do: :warning

  defp severity(other),
    do:
      raise(
        ArgumentError,
        "expected :error, :warning or :off as a rule severity, got: #{inspect(other)}"
      )

  defp validate_options!(module, options) do
    messages =
      [
        options[:message]
        | Enum.map(List.wrap(options[:contracts]), &Map.get(Map.new(&1), :message))
      ]
      |> Enum.flat_map(fn
        text when is_binary(text) -> [text]
        table when is_map(table) or is_list(table) -> for {_k, v} <- table, is_binary(v), do: v
        _ -> []
      end)

    for text <- messages, String.length(text) > Messages.max_length() do
      raise ArgumentError,
            "#{module.name()}: messages are limited to #{Messages.max_length()} characters"
    end

    :ok
  end

  # Globs relative to the root: ** crosses directories, * does not.
  defp glob(pattern) do
    regex =
      pattern
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part |> Regex.escape() |> String.replace("\\*", "[^/]*") |> String.replace("\\?", "[^/]")
      end)

    Regex.compile!("^(?:" <> regex <> ")$")
  end

  @doc """
  The rules for the file at `path` (relative to the root), after overrides:
  `{module, severity, options}` for every enabled rule.
  """
  @spec rules_for(t(), String.t()) :: [rule_setting()]
  def rules_for(%__MODULE__{} = config, path) do
    config.overrides
    |> Enum.filter(fn override -> Enum.any?(override.files, &Regex.match?(&1, path)) end)
    |> Enum.reduce(config.rules, fn override, rules ->
      Enum.reduce(override.rules, rules, fn {module, severity, options}, acc ->
        case List.keyfind(acc, module, 0) do
          nil ->
            acc ++ [{module, severity || :error, options || []}]

          {^module, old_severity, old_options} ->
            # A severity alone keeps the options set before it.
            List.keyreplace(
              acc,
              module,
              0,
              {module, severity || old_severity, options || old_options}
            )
        end
      end)
    end)
    |> Enum.reject(fn {_module, severity, _options} -> severity == :off end)
  end

  @doc """
  The recognition settings a rule works with: its own options over the
  shared settings.
  """
  @spec recognition(t(), keyword()) :: map()
  def recognition(%__MODULE__{settings: settings}, options) do
    Map.new(@recognition_keys, fn key ->
      {key, Keyword.get(options, key, Map.get(settings, key))}
    end)
  end
end
