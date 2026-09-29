defmodule HeexLint do
  @moduledoc """
  An agent-first linter for Tailwind classes in Phoenix HEEx templates, with
  rule parity with [@shadcn/lint](https://github.com/shadcn-ui/lint).

  Run it with `mix heex_lint`, or call `run/3`. See `HeexLint.Config` for
  configuration and the `HeexLint.Rules.*` modules for each rule.
  """

  alias HeexLint.{Config, Diagnostic, Messages, Project, Rule, Sites, Suppressions, Tailwind}

  # Class helpers known in the Elixir ecosystem, on top of the configured ones.
  @default_merge_functions ["cn", "Tails.classes", "TwMerge.merge", "Twix.tw"]

  @oracle_rules [HeexLint.Rules.NoUnknownClasses, HeexLint.Rules.NoRawColors]

  @type result :: %{
          diagnostics: [Diagnostic.t()],
          failures: [{String.t(), String.t()}],
          warnings: [String.t()],
          files: non_neg_integer()
        }

  @doc """
  Lints the files matched by the config's inputs, or `paths` when given.
  The whole project is read either way, so components resolve across files.

  Options: `:root`, the project root (default: the current directory).
  """
  @spec run(Config.t(), [String.t()] | nil, keyword()) :: result()
  def run(%Config{} = config, paths \\ nil, opts \\ []) do
    root = Path.expand(Keyword.get(opts, :root, File.cwd!()))
    project_files = files(config.inputs, root)
    targets = if paths, do: files(paths, root), else: project_files
    project = Project.load(root, Enum.uniq(project_files ++ targets), config.settings)
    lint(project, config, targets)
  end

  @doc false
  def lint(project, config, targets) do
    rules_by_file =
      Map.new(targets, &{&1, Config.rules_for(config, Path.relative_to(&1, project.root))})

    pairs =
      rules_by_file
      |> Map.values()
      |> List.flatten()
      |> Enum.map(fn {m, _s, o} -> {m, o} end)
      |> Enum.uniq()

    # The theme each file sees (its app's, in an umbrella).
    theme_files = Map.new(targets, &{&1, Project.for_file(project, &1).theme_file})
    themes = theme_files |> Map.values() |> Enum.uniq()

    oracle =
      if project.entry && Enum.any?(pairs, fn {module, _} -> module in @oracle_rules end) do
        {:ok, pid} = Tailwind.start_link(project)
        pid
      end

    project = %{project | oracle: oracle}

    # The project is large; tasks read it from persistent_term, which never
    # copies it onto their heaps.
    key = {__MODULE__, make_ref()}

    try do
      # One recognized project per distinct recognition setting, per run.
      recognized =
        pairs
        |> Enum.map(fn {_module, options} -> Config.recognition(config, options) end)
        |> Enum.uniq()
        |> Map.new(&{&1, Project.recognize(project, &1)})

      prepared =
        for {module, options} = pair <- pairs, theme_file <- themes, into: %{} do
          {{module, options, theme_file}, prepare(recognized, config, pair, theme_file)}
        end

      :persistent_term.put(key, {project, config, prepared})

      {diagnostics, failures} =
        targets
        |> Task.async_stream(
          fn path ->
            {project, config, prepared} = :persistent_term.get(key)
            lint_file(project, config, prepared, path, Map.fetch!(rules_by_file, path))
          end,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.reduce({[], []}, fn {:ok, {diagnostics, errors}}, {all, failures} ->
          {[diagnostics | all], [errors | failures]}
        end)

      warnings =
        project.warnings ++
          Enum.flat_map(Map.values(prepared), & &1.warnings) ++ Tailwind.warnings(oracle)

      %{
        diagnostics:
          diagnostics
          |> Enum.reverse()
          |> List.flatten()
          |> Enum.uniq_by(&{&1.file, &1.line, &1.column, &1.rule, &1.message})
          |> Enum.sort_by(&{&1.file, &1.line, &1.column}),
        failures: failures |> Enum.reverse() |> List.flatten(),
        warnings: Enum.uniq(warnings),
        files: length(targets)
      }
    after
      :persistent_term.erase(key)
      Tailwind.stop(oracle)
    end
  end

  # Each distinct {rule, options} compiles once, against the project as its
  # recognition options see it.
  defp prepare(recognized, config, {module, options}, theme_file) do
    recognition = Config.recognition(config, options)
    scoped = recognized |> Map.fetch!(recognition) |> themed(theme_file)

    placeholder_warnings =
      for text <- message_texts(options),
          warning <- Messages.check(text, Atom.to_string(module.name())),
          do: warning

    case module.prepare(options, scoped) do
      {:ok, state, warnings} ->
        %{
          state: state,
          error: nil,
          warnings: warnings ++ placeholder_warnings,
          project: scoped,
          recognition: recognition
        }

      {:error, message} ->
        %{
          state: nil,
          error: message,
          warnings: placeholder_warnings,
          project: scoped,
          recognition: recognition
        }
    end
  end

  # The project with a given theme: every file of an app shares its app's.
  defp themed(project, theme_file) do
    case Enum.find(Map.values(project.themes), &(&1.file == theme_file)) do
      nil -> project
      info -> %{project | theme: info.theme, theme_file: info.file, entry: info.entry}
    end
  end

  defp message_texts(options) do
    [
      options[:message]
      | Enum.map(List.wrap(options[:contracts]), &Map.get(Map.new(&1), :message))
    ]
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      table when is_map(table) or is_list(table) -> for {_k, v} <- table, is_binary(v), do: v
      _ -> []
    end)
  end

  defp lint_file(project, config, prepared, path, rules) do
    source = Map.fetch!(project.sources, path)
    theme_file = Project.for_file(project, path).theme_file

    if source.error do
      {[], [{path, source.error}]}
    else
      {diagnostics, errors} =
        rules
        |> Enum.group_by(fn {module, _severity, options} ->
          prepared[{module, options, theme_file}].recognition
        end)
        |> Enum.reduce({[], []}, fn {recognition, group}, {diagnostics, errors} ->
          [{module, _, options} | _] = group
          scoped = prepared[{module, options, theme_file}].project

          collected =
            Sites.collect(scoped, source,
              merge_functions: (recognition[:merge_functions] || []) ++ @default_merge_functions,
              variant_functions: recognition[:variant_functions] || []
            )

          file = %{
            project: scoped,
            source: source,
            sites: collected.sites,
            elements: collected.elements,
            note: config.settings[:note]
          }

          found =
            Enum.flat_map(group, fn {module, severity, options} ->
              case prepared[{module, options, theme_file}] do
                %{error: message} when is_binary(message) ->
                  [diagnostic(module, severity, path, Rule.config_error(message))]

                %{state: state} ->
                  file
                  |> module.check(state, options)
                  |> Enum.map(&diagnostic(module, severity, path, &1))
              end
            end)

          {diagnostics ++ found, Enum.uniq(errors ++ Enum.map(collected.errors, &{path, &1}))}
        end)

      {Suppressions.apply(diagnostics, source), errors}
    end
  end

  defp diagnostic(module, severity, path, finding) do
    {line, column} = finding.position

    %Diagnostic{
      rule: module.name(),
      severity: severity,
      file: path,
      line: line,
      column: column,
      message: finding.message,
      suggestions: Map.get(finding, :suggestions, [])
    }
  end

  @doc false
  def files(patterns, root) do
    patterns
    |> Enum.flat_map(fn pattern ->
      full = Path.expand(pattern, root)

      cond do
        File.dir?(full) -> Path.wildcard(Path.join(full, "**/*.{ex,exs,heex}"))
        File.regular?(full) -> [full]
        true -> Path.wildcard(full)
      end
    end)
    |> Enum.reject(&String.contains?(&1, ["/_build/", "/deps/", "/node_modules/"]))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
