defmodule HeexLint.Grammar.Similar do
  @moduledoc """
  Spelling distance for "did you mean". A transposition counts as one edit,
  since `foucs` is one slip away from `focus`. Ported from @shadcn/lint's
  `src/grammar/similar.ts` (MIT).
  """

  @doc """
  The optimal string alignment distance between `a` and `b`.

      iex> HeexLint.Grammar.Similar.edit_distance("foucs", "focus")
      1
  """
  @spec edit_distance(String.t(), String.t()) :: non_neg_integer()
  def edit_distance(a, b) do
    a = String.to_charlist(a) |> List.to_tuple()
    b = String.to_charlist(b) |> List.to_tuple()
    rows = tuple_size(a) + 1
    cols = tuple_size(b) + 1

    first = for j <- 0..(cols - 1), into: %{}, do: {{0, j}, j}

    d =
      Enum.reduce(1..(rows - 1)//1, first, fn i, d ->
        d = Map.put(d, {i, 0}, i)

        Enum.reduce(1..(cols - 1)//1, d, fn j, d ->
          cost = if elem(a, i - 1) == elem(b, j - 1), do: 0, else: 1

          value =
            Enum.min([
              Map.fetch!(d, {i - 1, j}) + 1,
              Map.fetch!(d, {i, j - 1}) + 1,
              Map.fetch!(d, {i - 1, j - 1}) + cost
            ])

          value =
            if i > 1 and j > 1 and elem(a, i - 1) == elem(b, j - 2) and
                 elem(a, i - 2) == elem(b, j - 1),
               do: min(value, Map.fetch!(d, {i - 2, j - 2}) + 1),
               else: value

          Map.put(d, {i, j}, value)
        end)
      end)

    Map.fetch!(d, {rows - 1, cols - 1})
  end

  @doc """
  The closest candidate within the edit `budget` (1 for values shorter than
  6 characters, 2 otherwise), ties broken alphabetically. `nil` when
  `value` is shorter than 3, when a candidate equals it, or when none is close.

      iex> HeexLint.Grammar.Similar.did_you_mean("primry", ["primary", "secondary"])
      "primary"
  """
  @spec did_you_mean(String.t(), Enumerable.t(), non_neg_integer() | nil) :: String.t() | nil
  def did_you_mean(value, candidates, budget \\ nil) do
    budget = budget || if String.length(value) < 6, do: 1, else: 2

    if String.length(value) < 3 do
      nil
    else
      candidates
      |> Enum.reduce_while(nil, fn name, best ->
        cond do
          name == value ->
            {:halt, :exact}

          abs(String.length(name) - String.length(value)) > budget ->
            {:cont, best}

          true ->
            distance = edit_distance(value, name)

            cond do
              distance > budget ->
                {:cont, best}

              best == nil ->
                {:cont, {name, distance}}

              distance < elem(best, 1) ->
                {:cont, {name, distance}}

              distance == elem(best, 1) and js_compare(name, elem(best, 0)) < 0 ->
                {:cont, {name, distance}}

              true ->
                {:cont, best}
            end
        end
      end)
      |> case do
        {name, _distance} -> name
        _ -> nil
      end
    end
  end

  # String.prototype.localeCompare for the ASCII names this compares: a
  # case-insensitive order that puts lowercase first on ties.
  defp js_compare(a, b) do
    case {String.downcase(a), String.downcase(b)} do
      {x, y} when x < y -> -1
      {x, y} when x > y -> 1
      _ -> if a == b, do: 0, else: if(a > b, do: -1, else: 1)
    end
  end
end
