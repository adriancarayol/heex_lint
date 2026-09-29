defmodule Mix.Tasks.HeexLint do
  @shortdoc "Lints Tailwind classes in HEEx templates"

  @moduledoc """
  Lints Tailwind classes in HEEx templates.

      $ mix heex_lint
      $ mix heex_lint lib/my_app_web/live
      $ mix heex_lint --format json
      $ mix heex_lint --fix

  Files default to the config's `:inputs` (see `HeexLint.Config`); the whole
  project is read either way, so components resolve across files.

  ## Options

    * `--config` - path to the config file (default `.heex_lint.exs`)
    * `--format` - `text` (default), `json`, or `github` for GitHub Actions
      annotations
    * `--max-warnings` - fail when there are more warnings than this
    * `--fix` - apply suggestions that have exactly one replacement, such
      as an exact scale step or a spelling correction, then lint again

  Exits with status 1 when there are errors, unreadable templates, or more
  warnings than `--max-warnings`.
  """

  use Mix.Task

  alias HeexLint.{Config, Fixer}

  @switches [config: :string, format: :string, max_warnings: :integer, fix: :boolean]

  @impl true
  def run(argv) do
    {options, paths, _invalid} = OptionParser.parse(argv, strict: @switches)

    config = Config.load(Keyword.get(options, :config, ".heex_lint.exs"))
    paths = if paths == [], do: nil, else: paths
    result = HeexLint.run(config, paths)

    result =
      if Keyword.get(options, :fix, false) do
        case Fixer.apply(result.diagnostics) do
          0 ->
            result

          count ->
            Mix.shell().info("Applied #{count} #{if count == 1, do: "fix", else: "fixes"}.")
            HeexLint.run(config, paths)
        end
      else
        result
      end

    for warning <- result.warnings, do: Mix.shell().error("warning: " <> warning)

    case Keyword.get(options, :format, "text") do
      "json" -> IO.puts(json(result))
      "github" -> github(result)
      _ -> text(result)
    end

    errors = Enum.count(result.diagnostics, &(&1.severity == :error))
    warnings = Enum.count(result.diagnostics, &(&1.severity == :warning))
    max_warnings = Keyword.get(options, :max_warnings)

    if errors > 0 or result.failures != [] or (max_warnings && warnings > max_warnings) do
      exit({:shutdown, 1})
    end
  end

  defp text(result) do
    for {file, message} <- result.failures do
      Mix.shell().error("#{Path.relative_to_cwd(file)}: could not parse template: #{message}")
    end

    for diagnostic <- result.diagnostics do
      label =
        case diagnostic.severity do
          :error -> IO.ANSI.format([:red, "error"])
          :warning -> IO.ANSI.format([:yellow, "warning"])
        end

      IO.puts(
        IO.iodata_to_binary([
          IO.ANSI.format([
            :faint,
            "#{Path.relative_to_cwd(diagnostic.file)}:#{diagnostic.line}:#{diagnostic.column}"
          ]),
          " ",
          label,
          " ",
          diagnostic.message,
          " ",
          IO.ANSI.format([:faint, "[#{diagnostic.rule}]"])
        ])
      )
    end

    IO.puts(summary(result))
  end

  defp summary(%{diagnostics: [], failures: [], files: files}),
    do: "\nNo problems in #{files} #{plural(files, "file")}."

  defp summary(result) do
    errors = Enum.count(result.diagnostics, &(&1.severity == :error))
    warnings = Enum.count(result.diagnostics, &(&1.severity == :warning))
    failures = length(result.failures)
    fixable = Enum.count(result.diagnostics, &Fixer.fixable?/1)

    parts =
      [{errors, "error"}, {warnings, "warning"}, {failures, "unparsable template"}]
      |> Enum.reject(&(elem(&1, 0) == 0))
      |> Enum.map_join(", ", fn {n, word} -> "#{n} #{plural(n, word)}" end)

    fix_hint = if fixable > 0, do: "\n#{fixable} can be fixed with --fix.", else: ""
    "\n#{parts} in #{result.files} #{plural(result.files, "file")}.#{fix_hint}"
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  # GitHub Actions workflow commands: findings become annotations on the
  # pull request's diff.
  defp github(result) do
    for {file, message} <- result.failures do
      IO.puts("::error file=#{Path.relative_to_cwd(file)}::#{escape(message)}")
    end

    for d <- result.diagnostics do
      level = if d.severity == :error, do: "error", else: "warning"

      location =
        "file=#{Path.relative_to_cwd(d.file)},line=#{d.line},col=#{d.column},title=#{d.rule}"

      IO.puts("::#{level} #{location}::#{escape(d.message)}")
    end
  end

  defp escape(message) do
    message
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  defp json(result) do
    JSON.encode!(%{
      diagnostics:
        Enum.map(result.diagnostics, fn d ->
          %{
            rule: d.rule,
            severity: d.severity,
            file: Path.relative_to_cwd(d.file),
            line: d.line,
            column: d.column,
            message: d.message,
            suggestions:
              Enum.map(d.suggestions, &%{message: &1.message, replacement: &1.replacement})
          }
        end),
      failures:
        Enum.map(result.failures, fn {file, message} ->
          %{file: Path.relative_to_cwd(file), message: message}
        end),
      warnings: result.warnings,
      files: result.files
    })
  end
end
