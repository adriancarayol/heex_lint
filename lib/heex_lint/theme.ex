defmodule HeexLint.Theme do
  @moduledoc """
  The design tokens a project defines in its Tailwind stylesheet.

  Reads CSS custom properties from the stylesheet and the local files it
  `@import`s. Properties inside `@theme` become Tailwind utilities
  (`--color-surface` gives `bg-surface`); other properties are used through
  the variable shorthand (`--surface` gives `bg-(--surface)`).
  """

  alias HeexLint.Color

  defstruct file: nil,
            variables: %{},
            theme_variables: MapSet.new(),
            colors: [],
            classes: MapSet.new()

  @type color :: %{
          variable: String.t(),
          utility: String.t(),
          value: String.t(),
          oklab: Color.oklab()
        }

  @type t :: %__MODULE__{
          file: String.t() | nil,
          variables: %{String.t() => String.t()},
          theme_variables: MapSet.t(String.t()),
          colors: [color()],
          classes: MapSet.t(String.t())
        }

  @doc """
  Loads the theme from `file`. Returns an empty theme when `file` is nil or missing.
  """
  @spec load(String.t() | nil) :: t()
  def load(nil), do: %__MODULE__{}

  def load(file) do
    if File.regular?(file) do
      {variables, theme_variables, classes} = read(file, MapSet.new())
      theme_variables = MapSet.new(theme_variables)
      variables = variables |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))

      %__MODULE__{
        file: file,
        variables: Map.new(variables),
        theme_variables: theme_variables,
        colors: colors(variables, theme_variables),
        classes: MapSet.new(classes)
      }
    else
      %__MODULE__{}
    end
  end

  @doc """
  Whether `name` (such as `--surface`) is defined by the theme.
  """
  @spec variable?(t(), String.t()) :: boolean()
  def variable?(%__MODULE__{variables: variables}, name), do: Map.has_key?(variables, name)

  @doc """
  Whether the theme defines a Tailwind color named `name`, such as `zinc-500` for `--color-zinc-500`.
  """
  @spec theme_color?(t(), String.t()) :: boolean()
  def theme_color?(%__MODULE__{theme_variables: vars}, name),
    do: MapSet.member?(vars, "--color-" <> name)

  @doc """
  Whether the stylesheet defines a plain CSS class starting with `prefix`, such as
  `.toast--error` for `toast--`.
  """
  @spec class_prefix?(t(), String.t()) :: boolean()
  def class_prefix?(%__MODULE__{classes: classes}, prefix),
    do: prefix != "" and Enum.any?(classes, &String.starts_with?(&1, prefix))

  @doc """
  Theme colors ordered by how close they look to `value`, closest first.
  """
  @spec closest_colors(t(), String.t()) :: [color()]
  def closest_colors(%__MODULE__{colors: colors}, value) do
    case Color.parse(value) do
      nil -> colors
      oklab -> Enum.sort_by(colors, &Color.distance(&1.oklab, oklab))
    end
  end

  # Returns variables in reverse definition order, the names declared inside
  # @theme, and the plain class selectors.
  defp read(file, seen) do
    if MapSet.member?(seen, file) or not File.regular?(file) do
      {[], [], []}
    else
      seen = MapSet.put(seen, file)
      css = file |> File.read!() |> String.replace(~r{/\*.*?\*/}s, "")

      imported =
        ~r/@import\s+(?:url\()?["']([^"']+)["']/
        |> Regex.scan(css)
        |> Enum.map(fn [_, path] -> path end)
        |> Enum.filter(&String.starts_with?(&1, "."))
        |> Enum.map(&read(Path.expand(&1, Path.dirname(file)), seen))

      theme_variables =
        ~r/@theme[^{]*\{([^}]*)\}/
        |> Regex.scan(css)
        |> Enum.flat_map(fn [_, body] -> body |> declarations() |> Enum.map(&elem(&1, 0)) end)

      classes =
        ~r/\.(-?[_a-zA-Z][\w-]*)/
        |> Regex.scan(css, capture: :all_but_first)
        |> List.flatten()

      Enum.reduce(imported, {Enum.reverse(declarations(css)), theme_variables, classes}, fn {v, t,
                                                                                             c},
                                                                                            {va,
                                                                                             ta,
                                                                                             ca} ->
        {v ++ va, t ++ ta, c ++ ca}
      end)
    end
  end

  defp declarations(css) do
    ~r/(?<![\w-])(--[\w-]+)\s*:\s*([^;{}]+?)\s*(?:;|(?=\}))/
    |> Regex.scan(css)
    |> Enum.map(fn [_, name, value] -> {name, value} end)
  end

  defp colors(variables, theme_variables) do
    lookup = Map.new(variables)

    for {name, value} <- variables,
        value = resolve(value, lookup, 5),
        oklab = Color.parse(value),
        oklab != nil,
        utility = utility(name, theme_variables),
        utility != nil,
        do: %{variable: name, utility: utility, value: value, oklab: oklab}
  end

  defp utility("--color-" <> color = name, theme_variables) do
    if MapSet.member?(theme_variables, name), do: color, else: "(#{name})"
  end

  defp utility(name, theme_variables) do
    # Other @theme namespaces (fonts, spacing, ...) are not colors.
    if MapSet.member?(theme_variables, name), do: nil, else: "(#{name})"
  end

  defp resolve(value, _lookup, 0), do: value

  defp resolve(value, lookup, depth) do
    case Regex.run(~r/^var\((--[\w-]+)\)$/, String.trim(value)) do
      [_, name] -> if lookup[name], do: resolve(lookup[name], lookup, depth - 1), else: value
      nil -> value
    end
  end
end
