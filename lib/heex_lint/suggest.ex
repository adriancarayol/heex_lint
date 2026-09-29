defmodule HeexLint.Suggest do
  @moduledoc false

  # Shared "use this instead" text for rule messages.

  alias HeexLint.{ClassName, Color, Rule, Theme}

  @max_colors 3

  @doc """
  Suggests the theme colors closest to `value` for the utility `prefix` (such as `bg`),
  keeping `suffix` (an opacity modifier such as `/10`).
  """
  def colors(%ClassName{} = class, prefix, value, context, suffix \\ "") do
    case rank(Theme.closest_colors(context.theme, value), prefix, value, context) do
      [] ->
        "Use a theme color, or add one to #{Rule.theme_file(context)} if the design calls for it."

      colors ->
        list =
          colors
          |> Enum.take(@max_colors)
          |> Enum.map_join(
            ", ",
            &"#{ClassName.with_utility(class, "#{prefix}-#{&1.utility}#{suffix}")} (#{&1.value})"
          )

        "Use the closest theme color: #{list}. Theme colors are in #{Rule.theme_file(context)}."
    end
  end

  # Colors within a small perceptual distance of the best match are treated as
  # equally good; among those, prefer the ones the project already uses with
  # this utility (a `text-*` color should come from the tokens used for text).
  @close_enough 0.08

  defp rank(colors, prefix, value, context) do
    case Color.parse(value) do
      target when colors != [] and target != nil ->
        rank_close(colors, prefix, target, Map.get(context, :color_usage, %{}))

      _ ->
        colors
    end
  end

  defp rank_close(colors, prefix, target, usage) do
    best = Color.distance(hd(colors).oklab, target)

    {close, rest} =
      Enum.split_with(colors, &(Color.distance(&1.oklab, target) <= best + @close_enough))

    close =
      Enum.sort_by(close, fn color ->
        {-Map.get(usage, {prefix, color.utility}, 0), Color.distance(color.oklab, target)}
      end)

    close ++ rest
  end
end
