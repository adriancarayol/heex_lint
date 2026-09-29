defmodule HeexLint.LintHelpers do
  @moduledoc false

  alias HeexLint.Config

  @theme Path.expand("../fixtures/app.css", __DIR__)

  @doc "The fixture theme's path."
  def theme, do: @theme

  @doc """
  Lints a `.heex` template with only `rule` enabled.
  """
  def lint(template, rule, options \\ []) do
    lint_file("test.heex", template, rule, options)
  end

  @doc """
  Lints `contents` as `file` with only `rule` enabled.
  """
  def lint_file(file, contents, rule, options \\ []) do
    config =
      Config.new(
        theme: Keyword.get(options, :theme, @theme),
        note: Keyword.get(options, :note),
        rules:
          Enum.map(Config.builtin_rules(), &{&1.name(), :off}) ++
            [{rule, {:error, Keyword.get(options, :rule, [])}}]
      )

    {:ok, diagnostics} = HeexLint.lint_source(file, contents, config)
    diagnostics
  end

  @doc "The messages of `diagnostics`."
  def messages(diagnostics), do: Enum.map(diagnostics, & &1.message)

  @doc "The `{line, column}` of each diagnostic."
  def positions(diagnostics), do: Enum.map(diagnostics, &{&1.line, &1.column})
end
