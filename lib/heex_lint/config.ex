defmodule HeexLint.Config do
  @moduledoc """
  Configuration, read from `.heex_lint.exs` in the project root.

      # .heex_lint.exs
      [
        inputs: ["lib/**/*.{ex,heex}"],
        theme: "assets/css/app.css",
        class_attributes: ["class", ~r/_class$/],
        note: "See DESIGN.md for the design rules.",
        rules: [
          no_raw_colors: :error,
          no_arbitrary_values: {:error, allow: ["grid-cols-[*"]},
          no_inline_styles: {:warning, allow: ["view-transition-name"]},
          require_static_classes: :error,
          no_unknown_variables: :error
        ]
      ]

  Every key is optional. A rule's setting is `:error`, `:warning`, `:off`, or
  `{severity, options}`. Rules left out use their default severity. A custom
  rule is a module implementing `HeexLint.Rule`, listed by module name.

  `note` is appended to every message, so agents see your own guidance too.
  """

  alias HeexLint.Rules

  @builtin [
    Rules.NoInlineStyles,
    Rules.NoArbitraryValues,
    Rules.NoRawColors,
    Rules.RequireStaticClasses,
    Rules.NoUnknownVariables
  ]

  @default_inputs ["lib/**/*.{ex,exs,heex}"]
  @default_themes ["assets/css/app.css", "assets/app.css", "priv/static/assets/app.css"]

  defstruct inputs: @default_inputs,
            theme: nil,
            class_attributes: ["class"],
            note: nil,
            rules: []

  @type severity :: :error | :warning
  @type t :: %__MODULE__{
          inputs: [String.t()],
          theme: String.t() | nil,
          class_attributes: [String.t() | Regex.t()],
          note: String.t() | nil,
          rules: [{module(), severity(), keyword()}]
        }

  @doc """
  Loads the config at `path`, falling back to defaults when it doesn't exist.
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
    %__MODULE__{
      inputs: Keyword.get(options, :inputs, @default_inputs),
      theme:
        Keyword.get_lazy(options, :theme, fn -> Enum.find(@default_themes, &File.regular?/1) end),
      class_attributes:
        Keyword.get_lazy(options, :class_attributes, fn -> ["class", ~r/_class$/] end),
      note: Keyword.get(options, :note),
      rules: rules(Keyword.get(options, :rules, []))
    }
  end

  @doc "The built-in rule modules."
  def builtin_rules, do: @builtin

  defp rules(settings) do
    by_name = Map.new(@builtin, &{&1.name(), &1})

    configured =
      Enum.map(settings, fn {key, setting} ->
        module =
          Map.get_lazy(by_name, key, fn ->
            if is_atom(key) and function_exported?(Code.ensure_compiled!(key), :check, 2),
              do: key,
              else: raise(ArgumentError, "unknown heex_lint rule #{inspect(key)}")
          end)

        {module, setting}
      end)

    defaults =
      for module <- @builtin, not List.keymember?(configured, module, 0), do: {module, :error}

    for {module, setting} <- defaults ++ configured,
        {severity, options} = normalize(setting),
        severity != :off,
        do: {module, severity, options}
  end

  defp normalize({severity, options}) when is_list(options), do: {severity(severity), options}
  defp normalize(severity), do: {severity(severity), []}

  defp severity(severity) when severity in [:error, :warning, :off], do: severity
  defp severity(:warn), do: :warning

  defp severity(other),
    do:
      raise(
        ArgumentError,
        "expected :error, :warning or :off as a rule severity, got: #{inspect(other)}"
      )
end
