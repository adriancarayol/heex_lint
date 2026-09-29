defmodule HeexLint.Suggest do
  @moduledoc """
  Naming the fix. A message that lists twelve tokens leaves the search to
  the reader; one that names the nearest two closes it. Ported from
  @shadcn/lint's `src/rules/suggest.ts` (MIT).
  """

  alias HeexLint.Grammar.{Colors, Lengths, TailwindTheme}

  # Beyond this, a suggestion looks nothing like the color reached for.
  @color_threshold 0.12

  # Tie order among tokens with the same value.
  @priority ~w(
    background foreground muted muted-foreground primary primary-foreground secondary
    secondary-foreground accent accent-foreground destructive destructive-foreground
    border input ring card card-foreground popover popover-foreground
  )

  @doc "Whether a color utility prefix paints text (`text-`) or a surface (`bg-`)."
  @spec role(String.t()) :: :text | :surface
  def role(prefix) do
    if Regex.match?(~r/^(?:text|placeholder|caret|decoration|fill|stroke)-$/, prefix),
      do: :text,
      else: :surface
  end

  defp foreground?(name), do: name == "foreground" or String.ends_with?(name, "-foreground")

  defp priority(name) do
    Enum.find_index(@priority, &(&1 == name)) || length(@priority)
  end

  @doc """
  The declared tokens nearest to `lab`, up to `limit`. Tokens that share a
  value collapse to one name; a surface is not offered `-foreground` tokens
  while a surface token is close.
  """
  @spec nearest_color_tokens(
          Colors.lab(),
          %{String.t() => Colors.lab()},
          :text | :surface,
          pos_integer()
        ) ::
          [String.t()]
  def nearest_color_tokens(lab, tokens, role, limit \\ 2) do
    prefer = if role == :text, do: &foreground?/1, else: &(not foreground?(&1))

    candidates =
      tokens
      |> Enum.flat_map(fn {name, value} ->
        distance = Colors.distance(lab, value)

        if distance > @color_threshold,
          do: [],
          else: [{:erlang.float_to_binary(distance, decimals: 3), distance, name}]
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {_key, group} ->
        distance = group |> hd() |> elem(1)

        name =
          group
          |> Enum.map(&elem(&1, 2))
          |> Enum.sort_by(&{if(prefer.(&1), do: 0, else: 1), priority(&1), &1})
          |> hd()

        {distance, name}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    candidates =
      if role == :surface and Enum.any?(candidates, &(not foreground?(&1))),
        do: Enum.reject(candidates, &foreground?/1),
        else: candidates

    Enum.take(candidates, limit)
  end

  @doc "The OKLab value of a default palette color such as `zinc-100`."
  @spec palette_color(String.t()) :: Colors.lab() | nil
  def palette_color(value) do
    case Map.get(TailwindTheme.palette(), value) do
      nil -> nil
      raw -> Colors.parse(raw)
    end
  end

  @doc "A color as written inside brackets: `#333`, `oklch(0.5_0.1_20)`."
  @spec arbitrary_color(String.t()) :: Colors.lab() | nil
  def arbitrary_color(inner) do
    inner |> String.replace(~r/^color:/, "") |> String.replace("_", " ") |> Colors.parse()
  end

  @doc "The scale steps nearest to `px`, closest first."
  @spec nearest_steps(number(), %{String.t() => number()}, pos_integer()) ::
          [%{name: String.t(), px: number(), exact: boolean()}]
  def nearest_steps(px, scale, limit \\ 2) do
    scale
    |> Enum.map(fn {name, value} -> %{name: name, px: value, exact: abs(value - px) < 0.01} end)
    |> Enum.sort_by(&{abs(&1.px - px), &1.px})
    |> Enum.take(limit)
  end

  @doc "Formats steps as `text-xs (12px), text-sm (14px)`."
  @spec format_steps([%{name: String.t(), px: number()}], (String.t() -> String.t())) ::
          String.t()
  def format_steps(steps, to_class) do
    Enum.map_join(steps, ", ", &"#{to_class.(&1.name)} (#{Lengths.format_px(&1.px)})")
  end
end
