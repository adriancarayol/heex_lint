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
    a = chars(a)
    b = chars(b)
    bounded(a, b, max(tuple_size(a), tuple_size(b)))
  end

  @doc """
  The distance between `a` and `b` when it is at most `budget`, or nil. Only the cells
  within `budget` of the diagonal can hold such a distance, so two long names cost
  their length and not its square.

      iex> HeexLint.Grammar.Similar.within("foucs", "focus", 1)
      1

      iex> HeexLint.Grammar.Similar.within("foucs", "bar", 1)
      nil
  """
  @spec within(String.t(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def within(a, b, budget), do: bounded(chars(a), chars(b), budget)

  defp chars(text), do: text |> String.to_charlist() |> List.to_tuple()

  defp bounded(a, b, budget) when abs(tuple_size(a) - tuple_size(b)) > budget, do: nil

  defp bounded(a, b, budget) do
    first = for slot <- 0..(2 * budget), do: first_cell(slot - budget, budget)
    first = List.to_tuple(first)

    case rows(a, b, 1, first, nil, budget) do
      nil ->
        nil

      last ->
        case elem(last, tuple_size(b) - tuple_size(a) + budget) do
          distance when distance <= budget -> distance
          _over -> nil
        end
    end
  end

  defp first_cell(column, _budget) when column >= 0, do: column
  defp first_cell(_column, budget), do: budget + 1

  defp rows(a, _b, row, previous, _before, _budget) when row > tuple_size(a), do: previous

  defp rows(a, b, row, previous, before, budget) do
    current = cells(a, b, row, 0, previous, before, budget, budget + 1, [])

    # A row's best is at most one more than the last one's, so a whole row over the
    # budget means every row after it is too.
    if Enum.min(Tuple.to_list(current)) > budget,
      do: nil,
      else: rows(a, b, row + 1, current, previous, budget)
  end

  # A slot is a column's distance from the diagonal, offset by the budget. So the
  # cell above is one slot on, and the cell two up and two left is the same slot.
  defp cells(_a, _b, _row, slot, _previous, _before, budget, _left, acc)
       when slot > 2 * budget,
       do: acc |> Enum.reverse() |> List.to_tuple()

  defp cells(a, b, row, slot, previous, before, budget, left, acc) do
    over = budget + 1
    column = row + slot - budget

    value =
      cond do
        column < 0 or column > tuple_size(b) ->
          over

        column == 0 ->
          min(row, over)

        true ->
          up = if slot < 2 * budget, do: elem(previous, slot + 1), else: over
          cost = if elem(a, row - 1) == elem(b, column - 1), do: 0, else: 1

          value = min(min(up, left) + 1, elem(previous, slot) + cost)

          if before != nil and column > 1 and elem(a, row - 1) == elem(b, column - 2) and
               elem(a, row - 2) == elem(b, column - 1),
             do: min(value, elem(before, slot) + 1),
             else: value
      end

    value = min(value, over)
    cells(a, b, row, slot + 1, previous, before, budget, value, [value | acc])
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
    length = String.length(value)
    budget = budget || if length < 6, do: 1, else: 2

    if length < 3 do
      nil
    else
      candidates
      |> Enum.reduce_while(nil, fn name, best ->
        cond do
          name == value ->
            {:halt, :exact}

          abs(String.length(name) - length) > budget ->
            {:cont, best}

          true ->
            distance = within(value, name, budget)

            cond do
              distance == nil ->
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
