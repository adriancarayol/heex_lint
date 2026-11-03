defmodule HeexLint.Grammar.ProjectClassifier do
  @moduledoc """
  The classifier the rules use: cn's grammar with the project's theme scales
  applied (a declared `--text-stat-label` makes `text-stat-label` a font
  size), then the project's CSS for what cn does not read. `bg-stripes` comes
  from a `--background-image-*` the grammar has no scale for, so it reads as a
  color, and a project's animations live in `@utility` as often as `@theme`. An
  `@utility` answers from its body in both cases: the properties it sets are
  categorized the way an arbitrary property is, so `@utility heading-2xs {
  font-size: 0.75rem }` is typography for the same reason `[font-size:1rem]`
  is. A theme that loads an `@config` or `@plugin` can add a font size its CSS
  never names, and there the theme's own Tailwind answers for `text-*`.
  Ported from @shadcn/lint's `src/project/namespaces.ts` (MIT).
  """

  alias HeexLint.Grammar.{Categories, Classes, Classifier}
  alias HeexLint.{Tailwind, Theme}

  # {class prefix, the @theme namespace it reads, the group it gives}. A
  # --color-* of the same name wins over the namespace, the way Tailwind reads
  # bg-* (verified against Tailwind 4.3.3): cn's scales cover the rest.
  @namespaces [{"bg-", "background-image-", "bg-image"}]

  @doc "The class group of `token` in a project with `theme`."
  @spec group_of(Theme.t() | nil, String.t()) :: String.t() | nil
  def group_of(theme, token) do
    # JavaScript can change without the stylesheets changing, and each run has its
    # own oracle, so such a theme's answers last no longer than the run.
    key = {__MODULE__, Theme.signature(theme), theme && theme.oracle, token}

    case Process.get(key, :miss) do
      :miss ->
        group = classify(theme, token)
        Process.put(key, group)
        group

      group ->
        group
    end
  end

  @doc "The category of `token`, or nil for layout and unknown classes."
  @spec category_of(Theme.t() | nil, String.t()) :: String.t() | nil
  def category_of(theme, token), do: Categories.category_of(group_of(theme, token))

  defp classify(theme, token) do
    group = Classifier.group_of(token, Theme.grammar(theme))

    cond do
      group == nil ->
        animation_group(theme, token) || utility_group(theme, token)

      Categories.category_of(group) != "color" ->
        group

      true ->
        theme_group(theme, token) || utility_group(theme, token) || module_group(theme, token) ||
          group
    end
  end

  # The grammar reads text-body as a color, knowing only the name.
  defp module_group(%Theme{oracle: {oracle, entry}}, token) do
    if String.starts_with?(Classes.normalize(token), "text-") and
         Tailwind.font_size?(oracle, entry, token) == true,
       do: "font-size"
  end

  defp module_group(_theme, _token), do: nil

  defp theme_group(nil, _token), do: nil
  defp theme_group(%Theme{file: nil}, _token), do: nil

  defp theme_group(theme, token) do
    base = Classes.normalize(token)

    with {prefix, namespace, group} <-
           Enum.find(@namespaces, fn {prefix, _, _} -> String.starts_with?(base, prefix) end),
         value when value != nil <- value_of(base, prefix),
         false <- MapSet.member?(theme.tokens, value),
         true <- MapSet.member?(theme.theme_names, namespace <> value) do
      group
    else
      _ -> nil
    end
  end

  # cn groups only Tailwind's own animations; a project's animation is one
  # its CSS declares: --animate-shimmer in @theme, or an @utility/selector.
  defp animation_group(nil, _token), do: nil
  defp animation_group(%Theme{file: nil}, _token), do: nil

  defp animation_group(theme, token) do
    base = Classes.normalize(token)

    cond do
      not String.starts_with?(base, "animate-") -> nil
      value_of(base, "animate-") == nil -> nil
      MapSet.member?(theme.theme_names, base) -> "animate"
      Theme.declares_class?(theme, token) -> "animate"
      true -> nil
    end
  end

  # A body that changes more than one thing is read as the first appearance
  # it carries, so a utility that paints and lays out is still paint. Layout
  # ranks last: it is what a body with nothing else in it leaves. An empty
  # body has no group.
  defp utility_group(nil, _token), do: nil

  defp utility_group(theme, token) do
    theme
    |> Theme.utility_properties_of(token)
    |> List.wrap()
    |> Enum.map(&Categories.property_group/1)
    |> Enum.min_by(&utility_rank/1, fn -> nil end)
  end

  defp utility_rank(group) do
    categories = Categories.categories()
    Enum.find_index(categories, &(&1 == Categories.category_of(group))) || length(categories)
  end

  # The value a utility looks up, without the opacity or line-height modifier.
  defp value_of(base, prefix) do
    rest = String.slice(base, String.length(prefix)..-1//1)
    value = String.replace(rest, Classes.opacity_modifier(), "")

    if value == "" or String.starts_with?(value, "[") or String.starts_with?(value, "("),
      do: nil,
      else: value
  end
end
