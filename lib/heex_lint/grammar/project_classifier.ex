defmodule HeexLint.Grammar.ProjectClassifier do
  @moduledoc """
  The classifier the rules use: cn's grammar, then the project's theme
  wherever the grammar's answer was a color it could not have known was
  something else (a declared `--text-stat-label` makes `text-stat-label` a
  font size), or no answer for an animation the project declares. An
  `@utility` answers from its body in both cases: the properties it sets are
  categorized the way an arbitrary property is, so `@utility heading-2xs {
  font-size: 0.75rem }` is typography for the same reason `[font-size:1rem]`
  is.
  Ported from @shadcn/lint's `src/project/namespaces.ts` (MIT).
  """

  alias HeexLint.Grammar.{Categories, Classes, Classifier}
  alias HeexLint.Theme

  # Longest prefix first: text-shadow-crisp is a text-shadow, not text
  # "shadow-crisp". `over_color`: whether the namespace wins over a
  # --color-* of the same name (verified against Tailwind 4.3.3).
  @namespaces [
    {"text-shadow-", "text-shadow-", "text-shadow", true},
    {"inset-shadow-", "inset-shadow-", "inset-shadow", true},
    {"drop-shadow-", "drop-shadow-", "drop-shadow", true},
    {"shadow-", "shadow-", "shadow", true},
    {"text-", "text-", "font-size", false},
    {"bg-", "background-image-", "bg-image", false}
  ]

  @doc "The class group of `token` in a project with `theme`."
  @spec group_of(Theme.t() | nil, String.t()) :: String.t() | nil
  def group_of(theme, token) do
    key = {__MODULE__, theme && theme.file, token}

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
    group = Classifier.group_of(token)

    cond do
      group == nil -> animation_group(theme, token) || utility_group(theme, token)
      Categories.category_of(group) != "color" -> group
      true -> theme_group(theme, token) || utility_group(theme, token) || group
    end
  end

  defp theme_group(nil, _token), do: nil
  defp theme_group(%Theme{file: nil}, _token), do: nil

  defp theme_group(theme, token) do
    base = Classes.normalize(token)

    with {prefix, namespace, group, over_color} <-
           Enum.find(@namespaces, fn {prefix, _, _, _} -> String.starts_with?(base, prefix) end),
         value when value != nil <- value_of(base, prefix),
         false <- not over_color and MapSet.member?(theme.tokens, value),
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
