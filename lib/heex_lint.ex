defmodule HeexLint do
  @moduledoc """
  An agent-first linter for Tailwind classes in Phoenix HEEx templates.

  Run it with `mix heex_lint`, or call `run/2` and `lint_source/3` directly.
  See `HeexLint.Config` for configuration.
  """

  alias HeexLint.{ClassName, Config, Diagnostic, Element, Rule, Template, Theme, Value}

  @type result :: %{
          diagnostics: [Diagnostic.t()],
          failures: [{String.t(), String.t()}],
          files: non_neg_integer()
        }

  @doc """
  Lints the files matched by the config's inputs, or `paths` when given.
  """
  @spec run(Config.t(), [String.t()] | nil) :: result()
  def run(%Config{} = config, paths \\ nil) do
    files = files(paths || config.inputs)

    {parsed, failures} =
      files
      |> Task.async_stream(&parse_file/1, timeout: :infinity, ordered: true)
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    elements = Enum.flat_map(parsed, fn {:ok, elements} -> elements end)

    %{
      diagnostics: lint(elements, config),
      failures: Enum.map(failures, fn {:error, failure} -> failure end),
      files: length(files)
    }
  end

  @doc """
  Lints `contents` as if it were the file `file`. Useful in tests and editors.
  """
  @spec lint_source(String.t(), String.t(), Config.t()) ::
          {:ok, [Diagnostic.t()]} | {:error, String.t()}
  def lint_source(file, contents, %Config{} = config) do
    case parse(file, contents) do
      {:ok, elements} -> {:ok, lint(elements, config)}
      {:error, {_file, message}} -> {:error, message}
    end
  end

  defp lint(elements, config) do
    context = %{
      theme: Theme.load(config.theme),
      class_attribute?: class_attribute_matcher(config.class_attributes),
      inline_variables: inline_variables(elements)
    }

    context = Map.put(context, :color_usage, color_usage(elements, context))

    for element <- elements,
        {rule, severity, options} <- config.rules,
        {{line, column}, message} <- rule.check(element, Map.put(context, :options, options)) do
      %Diagnostic{
        rule: rule.name(),
        severity: severity,
        file: element.file,
        line: line,
        column: column,
        message: if(config.note, do: message <> " " <> config.note, else: message)
      }
    end
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.file, &1.line, &1.column})
  end

  defp files(patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      if File.dir?(pattern),
        do: Path.wildcard(Path.join(pattern, "**/*.{ex,exs,heex}")),
        else: Path.wildcard(pattern)
    end)
    |> Enum.reject(&String.contains?(&1, ["/_build/", "/deps/", "_build/", "deps/"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_file(file), do: parse(file, File.read!(file))

  defp parse(file, contents) do
    with {:ok, templates} <- Template.from_file(file, contents) do
      Enum.reduce_while(templates, {:ok, []}, fn template, {:ok, acc} ->
        case Element.from_template(template) do
          {:ok, elements} -> {:cont, {:ok, acc ++ elements}}
          {:error, message} -> {:halt, {:error, {file, message}}}
        end
      end)
    else
      {:error, message} -> {:error, {file, message}}
    end
  end

  defp class_attribute_matcher(names) do
    fn name ->
      Enum.any?(names, fn
        %Regex{} = regex -> Regex.match?(regex, name)
        exact -> exact == name
      end)
    end
  end

  # CSS variables set in `style` attributes, such as `--progress` in `style="--progress: 40%"`.
  defp inline_variables(elements) do
    for element <- elements,
        %{name: "style", value: value} <- element.attributes,
        items <- Value.strings(value, element.indentation),
        [variable] <- Regex.scan(~r/--[\w-]+(?=\s*:)/, Value.text(items)),
        into: MapSet.new(),
        do: variable
  end

  # How often each utility prefix is used with each theme variable, such as
  # `{"text", "(--muted)"} => 12` for `text-(--muted)` and `text-[var(--muted)]`.
  # Suggestions prefer the tokens a project already uses for the same job.
  defp color_usage(elements, context) do
    for element <- elements,
        {:static, raw, _} <- Rule.class_tokens(element, context),
        %ClassName{utility: utility} = ClassName.parse(raw),
        [_, prefix, variable] <-
          [
            Regex.run(
              ~r/^([a-z-]+?)-(?:\((--[\w-]+)\)|\[(?:color:)?var\((--[\w-]+)\)\])(?:\/.*)?$/,
              utility
            )
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&(&1 |> Enum.reject(fn part -> part == "" end) |> Enum.take(3))),
        reduce: %{} do
      usage -> Map.update(usage, {prefix, "(#{variable})"}, 1, &(&1 + 1))
    end
  end
end
